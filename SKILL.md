---
name: arm64-vector-acceleration
description: "识别已经测量确认的 Arm64 CPU 热点，并安全实现、使能或审查 Neon、SVE 与 SVE2 向量加速，包括可移植 fallback、构建能力探测、运行时分派、正确性测试和可归因基准。用于分析、迁移、实现或审查原生代码的 Arm64 SIMD 优化；不用于普通 Arm64 构建或没有测量依据的性能猜测。"
---

# Arm64 向量加速

把测量确认的 Arm64 CPU 热点转化为最小且安全的向量化改动。保留可移植的生产路径，并使每项性能结论都能复现。

## 边界

- 遵守用户授权范围。分析或审查请求只检查并报告；实现请求只修改选定热点、构建接线、测试和必要文档。
- 先剖析再优化。源码形态、已有 x86 SIMD 路径或编译器报告只能提示候选，不能证明瓶颈。
- 分开记录事实、推断和未知项。编译成功、出现 SIMD 指令、HWCAP 可见、单项微基准或模拟器结果都不能单独证明加速成立。
- 除非已声明并验证部署 ISA 下限，否则不要给可分发的 baseline 目标全局添加 `-march=native`、`+sve` 或 `+sve2`。
- 保留当前最佳 fallback。不可用、变慢或验证失败的向量 tier 必须能够在不改变语义的情况下禁用或移除。
- 把 Neon、SVE、SVE2 和 SME 视为不同契约。不要把运行在 SVE2 CPU 上的 SVE1 实现称为 SVE2 实现。

## 选择工作模式

1. **发现：** 识别并排序已经测量的向量化候选；除非用户要求实现，否则以建议和证据结束。
2. **实现：** 建立 baseline，每次只增加一个 ISA tier 或一项编译器向量化改动，并在继续前完成验证。
3. **审查：** 追踪变更后的 kernel、构建参数、分派、fallback、测试和基准来源；先报告正确性或可移植性问题，再讨论收益。

按任务读取参考资料：

- 发现候选、选择 ISA 或寻找可迁移场景时，读取 [references/vectorization-use-cases.md](references/vectorization-use-cases.md)。
- 实现或审查 C/C++ 路径时，读取 [references/implementation-patterns.md](references/implementation-patterns.md)。
- 进行正确性验证或提出性能结论时，读取 [references/validation-and-evidence.md](references/validation-and-evidence.md)。

## 工作流与门禁

### 1. 确认来源和真实执行边界

- 记录仓库 revision、已有改动边界、目标架构、语言、编译器及版本、优化/LTO 参数、构建类型，以及 bare metal、容器、VM、guest 或交叉编译等实际运行边界。
- 找到架构特定实现、调用方、测试、基准和构建归属。符号与调用路径优先使用结构化代码工具，参数、宏和日志使用文本搜索。
- 需要 C 编译器和 Linux HWCAP 事实时，运行 skill 根目录中的 `scripts/probe-arm64-vector.sh`。Claude Code 使用 `${CLAUDE_SKILL_DIR}/scripts/probe-arm64-vector.sh`。编译探测与运行时探测是两类独立证据，都不能替代工作负载剖析。
- 在 VM 或容器中，从真正执行 kernel 的进程判断运行时能力；宿主机 CPU 特性不能证明 guest 已获得对应能力。

### 2. 测量并排序候选

- 复现代表性工作负载并收集 profiler 或 trace baseline，保留原始输出和完整命令。
- 按 inclusive/self cost、调用频率、输入规模和受影响的端到端时间占比排序；使用 Amdahl 定律排除系统影响上限过低的 kernel。
- 优先考虑 lane 之间独立且反复执行的密集计算，例如比较、搜索、计数、过滤、归约、变换、编解码、校验、解析和连续内存处理。
- 降低指针追逐、不可预测分支、同步、系统调用、分配、I/O 等待、小型冷循环、不规则 gather/scatter，以及禁止安全重排的语义的优先级。
- 先检查优化后的编译器输出和向量化报告。若自动向量化已经生成有效 tier，优先改善源码或 alias 信息，避免重复编写 intrinsic 实现。

**门禁：** 只有热点已经测量、scalar 语义明确，而且预期系统收益足以覆盖维护成本时，才实现 SIMD。

### 3. 设计 ISA 梯度

定义满足目标的最小梯度，通常为 `baseline -> Neon -> SVE`；只有使用了 SVE2 专属指令且证明有价值时才增加 SVE2。

- 按项目支持的 Arm64 最低要求编译 baseline。
- 对广泛分发的 Linux 二进制，使用符号化 `HWCAP_*`/`HWCAP2_*` 常量或项目已有 CPU feature 库限制 ISA 相关执行。只有明确且已验证的部署契约才能替代运行时 gate。
- 优先把 SVE/SVE2 放入独立 translation unit/object，只对该目标添加 feature 参数；配置阶段编译真实 header 和 intrinsic，并保留强制关闭选项。
- 在任何可选指令执行前完成分派；检查 LTO、内联、静态初始化和编译器生成指令是否把高阶 ISA 泄漏到 baseline。
- 使用 predicate 与 `svcnt*()` 编写 SVE vector-length-agnostic 循环。只有完整部署契约保证固定 VL 且测试覆盖时，才能固定向量长度。
- 分派开销有意义时，复用项目已有的线程安全初始化方式缓存选择结果。

**门禁：** baseline 制品必须能在没有可选 header/工具链支持时构建，并能在缺少可选 HWCAP 的硬件上启动和运行。

### 4. 每次只实现一个变量

- 先保留或建立独立 scalar oracle，明确比较、溢出、浮点、对齐、alias、tail 和空输入语义。
- 实现最窄的有效 tier。除非测量证明数据布局或公共接口就是瓶颈，否则保持它们不变。
- 对 predicated SVE load/store，根据剩余逻辑元素生成 predicate；predicate 必须阻止越界访问，不能只屏蔽算术结果。
- 复用项目已有分派和测试接口，不要创建第二套 CPU feature 注册表，也不要仅为测试引入永久公共 ABI。
- 检查差异是否产生了没有平台理由的重复状态或并行实现。

### 5. 证明正确性、隔离性和价值

- 直接把每个已编译 kernel 与独立 oracle 对比，再测试自动分派和负向 fallback。
- 覆盖 lane 边界、tail、空/小输入、极值、对齐、alias 和领域特定场景；随机测试使用固定 seed，外部输入解析可增加 property test 或 fuzzing。
- 检查对应 object 和最终制品，确认目标 tier 中存在预期指令，且 baseline 执行路径中没有可选指令。
- 在项目支持范围内覆盖无 SVE Arm64、SVE1 和 SVE2。模拟器只用于兼容性或正确性，不能用于性能结论。
- 在同一原生机器、工作负载、二进制策略和受控条件下比较变更前最佳生产路径与每个新 tier，保留全部有效样本和失败。
- 重新运行端到端工作负载，分别报告 kernel speedup 和系统影响；保留退化与无显著变化结果。

**门禁：** 只有功能检查通过、unsupported-hardware fallback 已证明，并且原生 A/B 显示值得维护且没有重大退化时，才建议默认启用新 tier。

## 必需输出

返回简洁且可核验的 evidence ledger，包含：

- 范围、revision、变更文件或分析边界；
- 已测量热点及其工作负载占比；
- 选择的 ISA 梯度，以及拒绝其他 tier 的理由；
- 编译/构建能力与运行时 HWCAP 的独立事实；
- 分派与 baseline 指令隔离证据；
- 包含逐目标结果的正确性矩阵；
- benchmark 身份、原始日志位置、样本数、失败、kernel 结果和端到端结果；
- 已验证事实、合理推断、剩余未知项、关闭/回退路径和最终建议。

若缺少硬件、权限、工具链、原始 baseline 或代表性工作负载，停在证据支持的最强结论，并给出下一步所需的准确命令或环境。
