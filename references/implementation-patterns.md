# Arm64 implementation patterns

Read this reference for C/C++ implementation or review. Adapt examples to the project's existing build and CPU-feature facilities instead of copying them mechanically.

## Selection order

1. Keep the production scalar/baseline path.
2. Inspect optimized assembly and compiler vectorization reports.
3. Prefer a source change that enables safe auto-vectorization when it is clear and stable.
4. Use Neon/SVE intrinsics when the compiler cannot express the kernel efficiently, exact instruction selection matters, or an existing multi-ISA design makes an intrinsic tier the simpler choice.
5. Use handwritten assembly only when native benchmark and disassembly evidence justify its higher ABI and maintenance cost.

For Clang, use the project's optimization level plus `-Rpass=loop-vectorize`, `-Rpass-missed=loop-vectorize`, and `-Rpass-analysis=loop-vectorize`. For GCC, use the current compiler's `-fopt-info-vec*` options. Diagnostics explain a compiler decision; disassembly and benchmarks establish what shipped and whether it helped.

## Keep optional ISA code contained

The most portable pattern is separate compilation:

```text
baseline TU/object: project Arm64 baseline; owns runtime detection and dispatch
Neon TU/object:     baseline or explicit Advanced SIMD contract
SVE TU/object:      -march=armv8.2-a+sve, scalable vector length
SVE2 TU/object:     only when it contains SVE2-specific code and has its own gate
```

Do not apply a higher `-march` to the whole library or executable. Exclude optional files from broad source globs, then add them only after configure-time compilation succeeds. Probe the header, feature macro, and at least one representative intrinsic, not only whether the compiler accepts a flag. Prefer capability probes over compiler-version comparisons.

For CMake, preserve the shape below while matching local conventions:

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

Do not run configure probes during cross compilation unless the build system explicitly supports execution on the target. A compile-only probe establishes toolchain support, not target HWCAP.

### LTO and inlining

Whole-program optimization can erase translation-unit containment. Use the project's supported no-LTO/no-inline boundary for optional kernels when necessary, or prove in the linked artifact that dispatch still dominates every path to optional instructions. Avoid optional-ISA code in headers, templates instantiated by baseline files, global constructors, and resolver code.

## Runtime feature detection

On Linux AArch64, use the current process's ELF auxiliary vector:

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

Prefer symbolic constants from platform headers. Do not hard-code bit positions, infer features from CPU model names, or use `/proc/cpuinfo` as the dispatch authority. Use an existing project CPU-feature library when it already models these facts correctly.

On non-Linux systems, use the operating system's documented feature-discovery API and keep it behind the same project dispatch abstraction; do not transplant Linux auxiliary-vector assumptions.

Compile-time macros such as `__ARM_FEATURE_SVE` describe the code-generation context; they do not prove the executing process may use SVE. Runtime HWCAP describes availability; it does not prove the optional object was compiled. Dispatch requires both facts.

If the deployment ABI guarantees Advanced SIMD, document that contract. Otherwise preserve a scalar gate for `HWCAP_ASIMD`. Always gate SVE and SVE2 for a binary intended to run across heterogeneous Arm64 systems.

Resolve the tier once when practical:

```text
if SVE2 object was built and HWCAP2_SVE2 and SVE2 beats lower tiers -> SVE2
else if SVE object was built and HWCAP_SVE -> SVE
else if Neon object was built and HWCAP_ASIMD -> Neon
else -> baseline
```

Use the project's thread-safe one-time initialization. A test-only override may force a lower supported tier for benchmarking, but it must reject a tier unavailable to the running process and must not become an undocumented production control.

## SVE kernel shape

Prefer vector-length-agnostic predicated loops:

```cpp
for (size_t i = 0; i < count;) {
    svbool_t pg = svwhilelt_b32(i, count);
    svuint32_t values = svld1_u32(pg, input + i);
    // Compute and reduce/store under pg.
    i += svcntw();
}
```

Match predicate element width to the data. Preserve signedness, comparison direction, overflow behavior, reduction order, and floating-point rules. Do not assume a particular SVE width or that a wider architectural vector produces a proportional speedup; implementations can have different execution bandwidth.

Use `-msve-vector-bits=scalable` or the compiler default for portable SVE. A numeric vector length is a deployment specialization and needs a runtime/packaging contract plus tests for that exact length.

SVE2 implies SVE availability, but SVE2-specific intrinsics/instructions require their own compile and HWCAP2 gate. If one SVE1 object serves both SVE1 and SVE2 CPUs, log it as `SVE` and optionally record `host_sve2=true`; do not label the implementation tier `SVE2`.

## Other languages

- **Rust:** inspect the pinned toolchain's `std::arch::aarch64` and `#[target_feature]` support before choosing intrinsics. Isolate optional functions, use runtime detection supported by that toolchain/platform, and audit inlining and LTO boundaries.
- **Go:** prefer existing architecture-specific files, build constraints, assembler conventions, and the pinned `x/sys/cpu` API. Do not invent a second feature detector. Direct SVE support varies with the assembler/toolchain, so verify current source and documentation.
- **Libraries/frameworks:** use their established multi-versioning or dispatch facility if it preserves baseline compatibility. Verify generated artifacts rather than assuming the abstraction contains the ISA.

## Authoritative references

- Arm ACLE, including Neon/SVE headers, feature macros, predicates, and vector-length rules: <https://arm-software.github.io/acle/main/acle.html>
- Linux arm64 ELF HWCAP contract: <https://docs.kernel.org/arch/arm64/elf_hwcaps.html>
- Current GCC AArch64 options: <https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html>
- Current Clang language extensions and vectorization diagnostics: <https://clang.llvm.org/docs/LanguageExtensions.html>

Check the pinned compiler/library documentation before implementation because feature APIs and attributes evolve.
