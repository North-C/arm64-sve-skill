# Arm64 向量化使用场景

发现候选、选择 ISA 或设计测试时读取本参考。这里的例子用于识别数据并行模式，不代表某个场景必然加速；必须先用真实工作负载测量，再决定是否实现。

## 场景地图

| 场景 | 常见数据模式 | 可考虑的 Arm64 路径 | 主要风险 |
| --- | --- | --- | --- |
| 批量搜索、比较、计数、过滤 | 连续数组逐元素比较后计数、生成 mask 或 compact | Neon compare/reduce；SVE predicate、`svcntp`、compact | 小输入、分支已经高度可预测、归约开销 |
| 文本与结构化数据解析 | 批量查找引号、分隔符、空白或字符集合 | Neon compare/table lookup；SVE predication；SVE2 `MATCH`/`svmatch_*` | UTF-8 边界、转义状态、越界读取、状态机依赖 |
| bitmap、bitset、Bloom filter | AND/OR/XOR、population count、批量 test/set | Neon/SVE 逻辑与 bit count；SVE2 bit/permute 能力 | 内存带宽、随机访问、并发原子更新 |
| 图像与视频 | 像素 clamp、颜色转换、卷积、滤波、行变换 | Neon widening/narrowing、saturating、multiply-accumulate；SVE/SVE2 分块 | 饱和与舍入语义、边缘像素、stride、格式布局 |
| 音频、DSP 与信号处理 | FIR/IIR、dot product、复数运算、采样格式转换 | Neon multiply-accumulate；DotProd；SVE/SVE2；可选 complex feature | 累加精度、overflow、定点缩放、实时尾延迟 |
| 压缩与编解码 | byte shuffle、查表、match、位流变换 | Neon table lookup；SVE2 byte/bit 操作与 predication | 跨块状态、位对齐、小包开销、已有汇编实现 |
| 量化 ML 推理 | INT8 dot product、widening accumulation、矩阵 micro-kernel | Neon DotProd/I8MM；SVE2 DotProd；可选 SVE I8MM/BF16 | 附加 feature gate、数据打包成本、溢出、已有 BLAS/kernel |
| 科学计算与 HPC | SAXPY、stencil、reduction、稀疏 gather、条件循环 | 编译器自动向量化；SVE VLA、predicate、gather/scatter | 浮点重排、NUMA/带宽、稀疏访问、向量执行带宽 |
| 密码与哈希 | AES、PMULL、SHA、批量 block 运算 | 使用已有库的 Neon/crypto/SVE2 tier | 额外 crypto feature、侧信道、禁止自制密码实现 |
| 网络报文处理 | 批量字段比较、checksum 辅助、分类、复制/变换 | Neon/SVE compare、table lookup、predicate | 短包、unaligned、跨包状态、分支与 cache miss |
| 序列化与数据格式转换 | byteswap、interleave/deinterleave、窄化/扩展、类型转换 | Neon load/store structure 与 shuffle；SVE/SVE2 predication | endian、alias、overlap、转换舍入、库函数已经优化 |
| 内存扫描与变换 | zero/find/copy/transform、连续 buffer 处理 | 编译器、libc；必要时 Neon/SVE predicated loop | 受内存带宽限制、短长度、non-temporal 策略、重复造轮子 |

## 典型模式

### 1. 阈值比较、计数与过滤

Scalar 语义通常类似：

```cpp
size_t count = 0;
for (size_t i = 0; i < n; ++i)
    count += values[i] <= threshold;
```

可选实现：

- Neon：固定宽度 load、compare、把 lane mask 归一化后做 horizontal reduction，最后处理 scalar tail。
- SVE：使用 `svwhilelt_*` 生成有效 lane，`svld1_*` load，`svcmp*` compare，使用 `svcntp_*` 计数，并按 `svcnt*()` 推进。
- 若结果需要输出匹配元素而非计数，评估 SVE compact/store 是否比 scalar scatter 更合适。

验证重点：signed/unsigned 比较、`<=` 与 `<` 的差异、极值、`n=0`、每个 lane/VL 边界，以及归约计数是否溢出。

### 2. 分隔符和字符集合扫描

CSV、JSON、日志和协议解析经常要查找多个特殊 byte，例如逗号、换行、引号和反斜杠。

- Neon 可以对每个 token 分别 compare 后 OR mask，也可以在适合的数据布局上使用 table lookup。
- SVE 可以利用 predicate 处理任意长度 tail。
- SVE2 的 `MATCH`/`svmatch_u8` 可以表达“输入 byte 是否属于 token 集合”，适合多 token 搜索，但必须单独 gate SVE2。

验证重点：不能把 batch 内“发现特殊字符”等同于完成 parser 状态转换；转义、字符串内部状态、UTF-8 continuation byte 和跨 chunk 状态仍需保持 scalar 语义。

### 3. Multiply-accumulate 与 dot product

常见于 DSP、卷积、相关计算和量化推理：

```cpp
int64_t sum = 0;
for (size_t i = 0; i < n; ++i)
    sum += static_cast<int32_t>(a[i]) * b[i];
```

选择路径时区分：

- 基础 Neon widening multiply-accumulate；
- 需要 `HWCAP_ASIMDDP` 等附加能力的 Neon DotProd；
- SVE/SVE2 对应的 scalable multiply/dot 路径；
- 需要独立 feature bit 的 I8MM、BF16 等扩展。

验证重点：输入 signedness、乘法宽度、accumulator 宽度、每轮归约顺序、overflow，以及重新打包数据的成本。若项目已使用 BLAS、oneDNN、XNNPACK 或其他成熟 kernel 库，先验证并复用其 dispatch。

### 4. 饱和、窄化与格式转换

图像、音频和网络格式转换经常包含 widen → compute → round/saturate → narrow：

```text
u8/s16 input -> widen -> multiply/add/shift -> saturating narrow -> output
```

Neon 对固定 128-bit block 的 widening、saturating 和 narrowing 支持成熟；SVE2 为更多通用数据处理补充相应能力。不要用普通截断替代饱和窄化，也不要在没有明确 rounding 契约时改变移位或转换顺序。

验证重点：上下饱和边界、负值、round-to-nearest 与 truncate、channel/stride 边界、unaligned row 和原地转换 alias。

### 5. 浮点数组与科学循环

规则的 SAXPY、stencil、矩阵 block 和 reduction 首先尝试编译器自动向量化。SVE 的 VLA 和 per-lane predication 对未知 VL、条件循环及部分向量有帮助；gather/scatter 只在访问模式和 cache 行为允许时使用。

验证重点：是否允许 reassociation/FMA、NaN、signed zero、subnormal、舍入模式和可重复性要求。kernel 提速如果受 memory bandwidth 限制，不能按 lane 数量外推。

### 6. Crypto、checksum 与 hash

AES、PMULL、SHA 等通常依赖独立于基础 Neon/SVE 的 crypto feature。应使用经过审查的库及其 multi-version dispatch，不要根据 `HWCAP_ASIMD` 或 `HWCAP_SVE` 推断 crypto 指令可用，也不要为了 SIMD 收益自行重写密码算法。

验证重点：known-answer test、constant-time/side-channel 属性、feature fallback、不同长度和 overlap 语义。普通 CRC/checksum 还可能使用 scalar CRC 扩展或成熟库路径，不应强制归类为向量优化。

### 7. 不规则 gather/scatter 与指针密集算法

SVE 提供 gather-load/scatter-store 并不表示链表、hash table 或稀疏访问一定适合向量化。先测量：

- lane 是否有足够独立工作；
- 地址是否集中到可复用 cache line；
- gather latency 是否能被计算覆盖；
- inactive lane、冲突写和 fault 行为是否正确；
- 更改数据布局是否比直接使用 gather 更有效。

如果主要成本是 cache miss、TLB miss 或同步，优先解决数据布局、批处理和并发，而不是增加 intrinsic。

## Feature gate 不能合并

| 能力 | 运行时事实示例 | 说明 |
| --- | --- | --- |
| Advanced SIMD/Neon | `HWCAP_ASIMD` | 只覆盖对应基础能力 |
| Neon DotProd | `HWCAP_ASIMDDP` | 不能由 `HWCAP_ASIMD` 推出 |
| SVE | `HWCAP_SVE` | 允许执行 SVE1；仍需确认 object 已构建 |
| SVE2 | `HWCAP2_SVE2` | 只为真实 SVE2 实现建立 tier |
| I8MM/BF16/crypto 等 | 对应平台 `HWCAP*` | 每项扩展独立检查，不能根据 CPU 名称猜测 |

具体 macro 与 HWCAP 名称必须以目标平台 header 和固定 toolchain 文档为准，不要硬编码数值 bit。

## 如何选择 Neon、SVE 或 SVE2

- **先选自动向量化：** 规则循环、明确 alias、编译器能生成理想指令且基准稳定。
- **选 Neon：** 固定小 block、128-bit 数据布局、广泛 Arm64 部署或项目已有 Neon seam。
- **选 SVE：** 输入长度变化大、需要 predicate/tail folding、VLA 部署、条件循环或经过验证的 gather/scatter。
- **选 SVE2：** byte/bit/permute、字符集合、DSP 或其他操作确实映射到 SVE2 专属指令，并且独立基准优于 SVE/Neon。
- **保留 baseline：** 输入很短、工作负载 I/O/内存受限、feature 覆盖不足、维护成本超过端到端收益，或验证不完整。

不要把 ISA 等级当作固定性能排序。128-bit SVE 可能不优于成熟 Neon，实现吞吐也可能小于架构 VL；必须逐 CPU、逐工作负载测量。

## 每类场景的最低验证

1. 用独立 oracle 证明语义一致。
2. 覆盖小输入、tail、unaligned、极值和领域状态边界。
3. 直接调用并测试每个已编译 tier。
4. 检查 object 和最终二进制中的真实指令与 gate。
5. 在同机上比较最佳生产 baseline、Neon、SVE 和真实 SVE2 tier。
6. 同时测 kernel 与代表性端到端工作负载。

## 权威参考

- Arm ACLE：<https://arm-software.github.io/acle/main/acle.html>
- Arm 关于 SVE/SVE2 SIMD 库使能：<https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/sve-sve2-enablement-in-simd-library>
- Arm SVE2 `SVMATCH` 多 token 搜索示例：<https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/multi-token-search-strings-svmatch-instruction>
- Arm Neon Dot Product intrinsic 与 feature 条件：<https://developer.arm.com/documentation/101028/latest/Advanced-SIMD--Neon--intrinsics>
- Arm Neon、SVE/SVE2 与 SME 矩阵计算对比：<https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/matrix-matrix-multiplication-neon-sve-and-sme-compared>

这些资料用于理解指令语义和适用模式，不能替代目标项目的 profiler、正确性测试和原生基准。
