# Arm64 实现模式

实现或审查 C/C++ 向量路径时读取本参考。应适配项目已有的构建系统和 CPU feature 设施，不要机械复制示例。

## 实现选择顺序

1. 保留生产环境使用的 scalar/baseline 路径。
2. 检查优化后的汇编和编译器向量化报告。
3. 如果通过清晰、稳定的源码改动即可安全触发自动向量化，优先采用该方式。
4. 当编译器无法有效表达 kernel、需要精确控制指令，或项目已有多 ISA 结构时，再使用 Neon/SVE intrinsic。
5. 只有原生基准和反汇编证明收益足以覆盖 ABI 与维护成本时，才使用手写汇编。

Clang 使用项目原有优化级别，并按需增加 `-Rpass=loop-vectorize`、`-Rpass-missed=loop-vectorize` 和 `-Rpass-analysis=loop-vectorize`。GCC 使用当前版本支持的 `-fopt-info-vec*` 参数。诊断信息解释编译器为何作出选择；反汇编和基准才能证明最终制品包含什么、是否有收益。

## 隔离可选 ISA 代码

通常最便于审查和移植的方式是独立编译：

```text
baseline TU/object: 项目 Arm64 baseline；负责运行时检测和分派
Neon TU/object:     baseline 或明确声明的 Advanced SIMD 契约
SVE TU/object:      -march=armv8.2-a+sve，使用 scalable vector length
SVE2 TU/object:     仅在包含 SVE2 专属代码并有独立 gate 时建立
```

不要把更高的 `-march` 应用到整个 library 或 executable。先从宽泛 source glob 中排除可选文件，再在配置阶段编译成功后显式加入。探针应覆盖 header、feature macro 和至少一个代表性 intrinsic，不能只检查编译器是否接受参数。优先使用能力探测，不依赖编译器版本字符串推断。

CMake 可以保留以下结构，并按项目约定调整：

```cmake
option(PROJECT_DISABLE_SVE "Disable SVE acceleration" OFF)
include(CheckCXXCompilerFlag)
include(CheckCXXSourceCompiles)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$" AND NOT PROJECT_DISABLE_SVE)
  check_cxx_compiler_flag("-march=armv8.2-a+sve" COMPILER_HAS_SVE_FLAG)
  set(SAVED_CMAKE_REQUIRED_FLAGS "${CMAKE_REQUIRED_FLAGS}")
  string(APPEND CMAKE_REQUIRED_FLAGS " -march=armv8.2-a+sve")
  check_cxx_source_compiles([=[
    #include <arm_sve.h>
    #ifndef __ARM_FEATURE_SVE
    #error SVE feature macro missing
    #endif
    int main() {
      svbool_t pg = svptrue_b32();
      return static_cast<int>(svaddv_u32(pg, svdup_u32(1)));
    }
  ]=] SVE_INTRINSICS_USABLE)
  set(CMAKE_REQUIRED_FLAGS "${SAVED_CMAKE_REQUIRED_FLAGS}")
  if(COMPILER_HAS_SVE_FLAG AND SVE_INTRINSICS_USABLE)
    target_sources(project_lib PRIVATE kernel_sve.cpp)
    set_source_files_properties(kernel_sve.cpp PROPERTIES
                                COMPILE_OPTIONS "-march=armv8.2-a+sve")
    target_compile_definitions(project_lib PRIVATE PROJECT_HAVE_SVE_OBJECT=1)
  endif()
endif()
```

交叉编译时，除非构建系统已经配置目标执行器，否则不要运行配置探针。compile-only 探针只证明工具链支持，不能证明目标机 HWCAP。

### LTO 与内联

全程序优化可能破坏 translation unit 隔离。必要时使用项目支持的 no-LTO/no-inline 边界，或者在最终链接制品中证明所有可选指令路径仍由运行时 gate 控制。避免把可选 ISA 代码放在 header、由 baseline 文件实例化的 template、全局构造函数或 feature resolver 中。

## 运行时 feature 检测

Linux AArch64 应读取当前进程的 ELF auxiliary vector：

```cpp
#include <asm/hwcap.h>
#include <sys/auxv.h>

const unsigned long hwcap = getauxval(AT_HWCAP);
const bool have_neon = (hwcap & HWCAP_ASIMD) != 0;
const bool have_sve = (hwcap & HWCAP_SVE) != 0;

#if defined(AT_HWCAP2) && defined(HWCAP2_SVE2)
const bool have_sve2 = (getauxval(AT_HWCAP2) & HWCAP2_SVE2) != 0;
#else
const bool have_sve2 = false;
#endif
```

优先使用平台 header 中的符号常量。不要硬编码 bit 位置，不要根据 CPU 型号推断，也不要把 `/proc/cpuinfo` 作为分派权威。如果项目已有正确建模这些能力的 CPU feature 库，应直接复用。

非 Linux 系统使用对应操作系统的正式 feature discovery API，并隐藏在同一项目分派抽象后；不要移植 Linux auxiliary-vector 假设。

`__ARM_FEATURE_SVE` 等编译期 macro 描述代码生成上下文，不能证明执行进程可以使用 SVE。运行时 HWCAP 描述 feature 可用性，也不能证明可选 object 已经构建。安全分派必须同时满足两类条件。

如果部署 ABI 明确保证 Advanced SIMD，应记录该契约；否则为 `HWCAP_ASIMD` 保留 scalar gate。面向异构 Arm64 环境的二进制始终需要 gate SVE 和 SVE2。

通常只解析一次 tier：

```text
if 已构建 SVE2 object && HWCAP2_SVE2 && SVE2 实测优于低阶 tier -> SVE2
else if 已构建 SVE object && HWCAP_SVE -> SVE
else if 已构建 Neon object && HWCAP_ASIMD -> Neon
else -> baseline
```

复用项目已有的线程安全 one-time initialization。测试专用 override 可以强制选择较低且受支持的 tier，但必须拒绝当前进程不可用的 tier，且不能成为未记录的生产控制接口。

## SVE kernel 形态

优先使用 vector-length-agnostic predicated loop：

```cpp
for (size_t i = 0; i < count;) {
    svbool_t pg = svwhilelt_b32(i, count);
    svuint32_t values = svld1_u32(pg, input + i);
    // Compute and reduce/store under pg.
    i += svcntw();
}
```

predicate 的元素宽度必须与数据匹配。保持 signedness、比较方向、溢出行为、归约顺序和浮点规则。不要假设具体 SVE 宽度，也不要假设架构向量更宽就会按比例提速；不同 CPU 的实际执行带宽可能不同。

可移植 SVE 使用 `-msve-vector-bits=scalable` 或编译器默认设置。数值型固定 VL 属于部署特化，必须同时具备运行时/打包契约和对应 VL 测试。

SVE2 CPU 同时支持 SVE，但 SVE2 专属 intrinsic/指令仍需要独立的编译与 HWCAP2 gate。如果一个 SVE1 object 同时服务 SVE1 和 SVE2 CPU，应记录为 `SVE`，可以另记 `host_sve2=true`，不能把实现 tier 标成 `SVE2`。

## 其他语言

- **Rust：** 先检查固定 toolchain 中 `std::arch::aarch64` 和 `#[target_feature]` 的实际支持，再选择 intrinsic。隔离可选函数，使用该 toolchain/平台支持的运行时检测，并审查内联与 LTO 边界。
- **Go：** 优先采用项目已有的架构文件、build constraint、assembler 约定和固定版本 `x/sys/cpu` API，不要创建第二套 feature detector。Go assembler/toolchain 对 SVE 的支持会变化，实施前核对当前源码和官方文档。
- **库或框架：** 如果已有 multi-versioning 或 dispatch 设施且能保持 baseline 兼容，应直接复用。必须检查生成制品，不能假设抽象层已经正确隔离 ISA。

## 权威参考

- Arm ACLE，包括 Neon/SVE header、feature macro、predicate 和 vector-length 规则：<https://arm-software.github.io/acle/main/acle.html>
- Linux arm64 ELF HWCAP 契约：<https://docs.kernel.org/arch/arm64/elf_hwcaps.html>
- GCC AArch64 参数：<https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html>
- Clang language extension 与向量化诊断：<https://clang.llvm.org/docs/LanguageExtensions.html>

feature API 与 attribute 会演进；实施前必须核对项目固定版本的编译器或库文档。
