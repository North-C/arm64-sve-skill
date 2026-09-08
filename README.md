# Arm64 Vector Acceleration Skill

`arm64-vector-acceleration` 是一套面向原生代码项目的 Arm64 SIMD 优化工作流，用于从真实性能热点出发，鉴别并安全使能 Neon（Advanced SIMD）、SVE 和 SVE2 加速。

它不只是添加 `-march` 编译参数，而是覆盖完整工程链路：热点测量、候选判断、ISA 分层、编译隔离、运行时分派、正确性验证、二进制检查以及可归因的性能测试。

## 适用场景

- 从 profiler 或 trace 中寻找适合 Arm64 向量化的 CPU 热点。
- 将已有的 x86 SSE/AVX/AVX-512 优化迁移到 Neon、SVE 或 SVE2。
- 为标量循环增加编译器自动向量化或 ACLE intrinsic 实现。
- 审查现有 Arm64 SIMD 补丁是否存在兼容性、越界、错误分派或性能证据不足的问题。
- 为同时运行在普通 Arm64、Neon、SVE1 和 SVE2 机器上的二进制设计安全 fallback。

以下情况不适合直接使用本 skill：没有测量数据的性能猜测、单纯的 Arm64 交叉编译、主要受 I/O/锁/系统调用限制的负载，以及没有代表性输入和基线的“开启 SVE”请求。

## 核心能力

| 能力 | 作用 |
| --- | --- |
| 热点发现 | 根据 self/inclusive cost、调用频率、输入规模和端到端占比筛选候选 |
| 向量化评估 | 识别连续比较、搜索、过滤、归约、编解码、校验和等适合并行的数据路径 |
| 自动向量化诊断 | 使用编译器报告和反汇编判断是否已经生成有效 SIMD，避免重复实现 |
| ISA 梯度设计 | 按需建立 `baseline -> Neon -> SVE -> SVE2` 路径，而不是提升整个二进制的 ISA 下限 |
| 构建隔离 | 将 SVE/SVE2 放入独立 translation unit/object，并使用真实 intrinsic 做工具链探测 |
| 运行时分派 | 根据当前进程可见的 `HWCAP_ASIMD`、`HWCAP_SVE` 和 `HWCAP2_SVE2` 选择实现 |
| SVE VLA 实现 | 使用 predicate 和 `svcnt*()` 编写不绑定固定向量长度的循环 |
| 正确性验证 | 使用独立 scalar oracle、边界值、固定种子随机数据和分派负向测试验证每个 tier |
| 制品检查 | 检查目标指令是否生成，以及 LTO/内联是否把高阶 ISA 泄漏到 baseline 路径 |
| 性能归因 | 分别报告 kernel 与端到端收益，保留完整样本、失败、环境身份和回退结论 |

## 工作模式

skill 根据请求选择三种模式：

1. `Discover`：只分析和排序候选热点，不修改代码。
2. `Implement`：建立基线，每次实现并验证一个 ISA tier。
3. `Review`：检查已有补丁的 kernel、构建参数、分派、fallback、测试和性能证据。

无论哪种模式，都遵循同一条证据链：

```text
确认源码和运行边界
  -> 测量并选择热点
  -> 设计最小 ISA 梯度
  -> 隔离实现和运行时分派
  -> 正确性、制品、微基准和端到端验证
  -> 给出启用、保留实验状态或回退的结论
```

## 快速使用

在包含本 skill 的仓库中，可以直接提出类似请求：

```text
使用 $arm64-vector-acceleration 分析当前项目的 CPU profile，找出最值得进行 Neon/SVE 优化的三个函数，只给出候选和证据，不修改代码。
```

```text
使用 $arm64-vector-acceleration 为 parse_block 实现 baseline、Neon 和 SVE 分派，保留无 SVE 机器的兼容路径，并完成正确性与原生 A/B 测试。
```

```text
使用 $arm64-vector-acceleration 审查这个 SVE 补丁，重点检查 HWCAP 分派、尾部 predicate、LTO 指令泄漏和基准可归因性。
```

迁移到其他仓库时，应复制完整的 `arm64-vector-acceleration/` 目录到目标仓库的 `.agents/skills/`，不要只复制 `SKILL.md`，否则会丢失探针和按需参考资料。

## 环境预检脚本

脚本 [scripts/probe-arm64-vector.sh](scripts/probe-arm64-vector.sh) 用于收集两类相互独立的事实：

- `compile.*`：所选编译器能否编译 Neon、SVE、SVE2 header、feature macro 和代表性 intrinsic。
- `runtime.*`：当前 Linux AArch64 进程是否获得对应 HWCAP，以及当前 SVE vector length。

使用默认 C 编译器：

```bash
./scripts/probe-arm64-vector.sh
```

使用指定编译器：

```bash
ARM64_VECTOR_CC=clang ./scripts/probe-arm64-vector.sh
ARM64_VECTOR_CC=aarch64-linux-gnu-gcc ./scripts/probe-arm64-vector.sh
```

典型输出：

```text
compiler.target=aarch64-linux-gnu
compile.neon=yes
compile.sve=yes
compile.sve2=yes
runtime.arch=aarch64
runtime.neon=yes
runtime.sve=yes
runtime.sve2=yes
runtime.sve_vl_bytes=32
```

需要正确解释这些结果：

- `compile.sve=yes` 只说明工具链能够生成 SVE，不说明部署机器可以执行。
- `runtime.sve=yes` 只说明当前进程获得了 SVE，不说明项目已经构建或选择了 SVE kernel。
- 交叉编译器探测不能替代目标机执行验证。
- HWCAP、编译成功或反汇编看到指令，都不能单独证明实际业务性能提升。

脚本只在私有临时目录生成探测对象并在退出时清理，不修改项目源码或系统配置。

## 验证状态

截至 2026-09-08，探针完成了以下验证：

- x86_64 上正确报告三个 Arm 编译探测为 `no`，并跳过 Linux AArch64 运行时探测。
- openEuler 24.03 AArch64 上，GCC 12.3.1 和 Clang 17 均通过 Neon、SVE、SVE2 intrinsic 编译探测。
- 同一 AArch64 环境中，当前进程报告 Neon、SVE、SVE2 可用，SVE VL 为 32 bytes。
- GCC 和 Clang 的 C++ SVE/CMake 探测片段均通过语法编译。
- 缺失编译器、非 Arm 主机和临时目录清理路径已验证。

这些结果验证的是 skill 探针，不是任意目标项目的 SIMD 正确性或性能。真实优化仍需在目标项目中重新建立 baseline，并执行正确性、fallback、反汇编和原生 A/B 测试。

## 输出结果

一次完整使用应形成可核验的 evidence ledger，至少包含：

- 仓库 revision、dirty boundary 和分析/修改范围；
- 原始 profile、热点占比和候选判断；
- ISA 梯度及未选择其他 tier 的原因；
- 编译器探测与运行时 HWCAP，二者分别记录；
- 分派路径和 baseline 指令隔离证据；
- 每个目标环境的正确性结果；
- benchmark 命令、原始日志、样本总数、失败和排除项；
- kernel speedup 与端到端变化；
- 已验证事实、合理推断、未知项和回退方式。

详细验证矩阵与记录模板见 [references/validation-and-evidence.md](references/validation-and-evidence.md)。

## 目录结构

```text
arm64-vector-acceleration/
├── README.md
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   ├── implementation-patterns.md
│   ├── overlaybd-case-study.md
│   └── validation-and-evidence.md
└── scripts/
    └── probe-arm64-vector.sh
```

- [SKILL.md](SKILL.md)：触发条件、工作模式、主流程和强制门禁。
- [references/implementation-patterns.md](references/implementation-patterns.md)：C/C++、CMake、HWCAP、LTO 和 SVE VLA 实现模式。
- [references/validation-and-evidence.md](references/validation-and-evidence.md)：兼容性矩阵、正确性测试、制品检查和基准规范。
- [references/overlaybd-case-study.md](references/overlaybd-case-study.md)：从 OverlayBD LSMT 优化中提炼的真实案例和证据边界。
- [scripts/probe-arm64-vector.sh](scripts/probe-arm64-vector.sh)：工具链与运行时能力探针。
- [agents/openai.yaml](agents/openai.yaml)：skill 的界面名称、简介和默认提示词。

## 当前边界

- C/C++ 和 CMake 提供了最完整的实现指导。
- Rust 和 Go 目前提供工具链、feature detection 和隔离原则，没有完整的通用代码模板。
- 不包含自动 profiler 驱动、自动生成向量 kernel 或通用 benchmark harness。
- 不把模拟器结果用于性能结论，也不把单一微基准结果直接外推为系统收益。
- 不保证 Neon、SVE 或 SVE2 一定更快；正确但没有收益的实现应保持实验状态或删除。

## 方法来源

本 skill 的初始工程方法来自 containerd/overlaybd 的 LSMT inner-search Arm64 优化：利用已有 AVX-512 架构切入点，增加 Neon 和独立 SVE translation unit，通过编译能力探测与运行时 HWCAP 分派保持兼容，并使用独立标量实现交叉验证。

该案例的实现事实和性能证据边界记录在 [references/overlaybd-case-study.md](references/overlaybd-case-study.md)。通用化过程同时遵循 Arm ACLE、Linux arm64 ELF HWCAP、GCC 与 Clang 的当前接口约定；在具体项目实施前仍应核对其固定版本的编译器和依赖文档。
