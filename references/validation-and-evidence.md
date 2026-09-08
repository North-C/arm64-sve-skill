# 验证与证据

在宣称正确性、兼容性或性能之前读取本参考。

## 三项独立结论

始终分开判断：

1. **工具链与指令隔离：** 构建系统能够生成可选 object，同时保持可分发 baseline 的兼容性。
2. **功能正确性：** 每个 kernel 和运行时分派在所有支持输入与目标上保持语义一致。
3. **性能价值：** 向量 tier 在选定的原生工作负载中产生足以覆盖维护成本的收益。

任意一项通过都不能推出另外两项。

## 最小兼容性矩阵

根据项目实际支持策略调整矩阵；每个单元格都记录为通过、失败、说明原因的跳过或未运行。

| 目标 | 构建 | 启动/fallback | 直接 kernel 正确性 | 分派 | 原生性能 |
| --- | --- | --- | --- | --- | --- |
| 非 Arm CI | baseline；排除可选 TU | N/A | 架构测试显式跳过 | N/A | N/A |
| 无 SVE Arm64 | baseline + 受支持的 Neon | 不得执行 SVE | baseline/Neon | 选择低阶 tier | 可选 Neon A/B |
| Arm64 SVE1 | 包含 SVE object | 通过 | baseline/Neon/SVE | 选择 SVE | SVE 结论必需 |
| Arm64 SVE2 | SVE1 与可选的真实 SVE2 object | 通过 | 所有已编译 tier | 选择最高有效 tier | SVE2 结论必需 |
| 最低/旧工具链 | 不支持时禁用可选 object | baseline 可用 | baseline 测试 | baseline/低阶 tier | N/A |

VM 环境还要记录 guest kernel、VMM CPU 配置和 guest 内部观察到的 feature。交叉编译应分开记录 builder 与 execution target 身份。

## 正确性设计

从语义契约独立编写 scalar oracle，不要与向量实现共享容易同时出错的 helper。直接调用每个已编译 tier，避免错误 kernel 被自动分派隐藏。

按操作选择测试输入：

- 长度为 0、1 和其他小值；
- 刚好低于、等于和高于 Neon lane 分组及每个观测到的 SVE VL；
- unaligned address 以及合法 alias/overlap 模式；
- 整数最小/最大值、signed 边界、进位、饱和与归约溢出；
- 搜索/过滤 kernel 的 exact-hit、no-hit、all-hit、有序、重复和对抗分布；
- 浮点 NaN、无穷、signed zero、subnormal、rounding 和 reassociation 策略；
- 固定 seed 的随机/property test，以及面向外部输入的 fuzzing；
- 共享分派状态在并发首次调用时的初始化行为。

运行项目支持的 sanitizer。Predicated load 仍然需要正确 predicate 和有效 base pointer。任何重试前先分析失败，不能把一次重试成功改写为原测试通过。

自动选择与直接 kernel 分开测试：

- 通过现有诊断接口记录或暴露所选 tier；
- 证明没有 `HWCAP_SVE` 时不会选择 SVE；
- 证明只有同时存在已编译 SVE2 实现和 `HWCAP2_SVE2` 时才会选择 SVE2；
- 证明应用能在 unsupported machine 上启动并完成代表性操作；
- 证明关闭/回退开关能够选择低阶 tier。

## 制品检查

使用项目可用且能识别目标架构的 `objdump`/`llvm-objdump`、`readelf` 和 symbol 工具检查每个 tier object 与最终制品。

记录：

- 每个 tier 的编译命令或 compile database entry；
- kernel 与 dispatch 周围的反汇编；
- 预期 Neon/SVE/SVE2 指令确实存在的证据；
- 可选指令在运行时 gate 前不可达的证据；
- LTO/内联状态和 symbol 所属 object；
- 打包或交叉编译时的 dynamic loader 与架构身份。

不能只根据源码 macro 或 object flag 推断最终二进制兼容性。

## 基准协议

必要时保留两个 scalar 概念：

- **oracle scalar：** 以清晰和独立为目标，用于语义校验；
- **变更前最佳生产路径：** 使用正常生产参数编译，作为性能 baseline。

防止 dead-code elimination，并在基准运行中校验输出。检查 baseline 反汇编：若所谓 scalar 已被编译器自动向量化，它不能作为纯 scalar kernel 对比，但仍可能是正确的生产 baseline。

随原始日志记录以下身份：

- commit/diff 和已有改动边界；
- CPU 型号、拓扑、当前进程 HWCAP/HWCAP2，以及相关 microcode/firmware；
- OS/kernel、bare-metal/container/VM 身份和 guest CPU 暴露；
- 编译器/链接器版本与完整参数，包括 LTO 和 VL 策略；
- 每轮运行选择的 tier 和 SVE VL；
- 工作负载/数据身份、输入规模与分布、线程数、affinity/NUMA 放置；
- governor/频率策略、竞争负载、warm-up、cooldown、运行顺序和重复次数。

所有 tier 使用同一机器和受控条件。存在时间漂移风险时随机化或交替运行顺序。保留逐轮数据、错误、超时与排除项，并给出完整 denominator。根据指标选择合适统计量并报告不确定性，不能只展示最佳样本。

同时测量：

- **kernel/microbenchmark：** 每操作 cycle 或时间、throughput，以及 instruction、branch、cache/TLB miss、memory bandwidth 等有用 counter；
- **代表性端到端工作负载：** 在相同成功条件下测量用户可见 latency、throughput 或资源成本。

使用已测量的热点占比 `p` 和 kernel speedup `s` 检查系统收益上限：

```text
最大预期整体加速比 = 1 / ((1 - p) + p / s)
```

如果观测到的端到端变化与该上限明显矛盾，应调查工作负载漂移、测量错误或所选 kernel 之外的影响。

QEMU 等模拟器可以扩展不同 VL 和 feature 组合的功能覆盖，但不能建立原生 latency、throughput 或能耗结论。

## 决策记录模板

```text
范围/revision：
请求模式：发现 | 实现 | 审查
工作负载与原始 baseline：
已测量热点及占比：
语义契约：
候选评估：
ISA 梯度与拒绝的 tier：
构建探测：
运行时 HWCAP 事实：
隔离/反汇编证据：
正确性矩阵：
基准身份与原始日志：
kernel 结果：
端到端结果：
失败/排除项/denominator：
关闭或回退路径：
已验证事实：
合理推断：
未知项和下一步验证：
建议：
```

只有证据满足项目的兼容性和维护策略时，才建议默认启用。实现正确但收益中性时，可以保持实验状态或删除。
