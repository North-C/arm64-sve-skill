---
name: arm64-vector-acceleration
description: Identify measured Arm64 CPU hotspots and safely implement, enable, or review Neon (Advanced SIMD), SVE, and SVE2 acceleration with portable fallbacks, build-time feature probes, runtime dispatch, correctness tests, and attributable benchmarks. Use for native-code SIMD optimization or an existing Arm64 vector patch; do not use for generic Arm64 builds or unmeasured performance speculation.
---

# Arm64 Vector Acceleration

Turn a measured Arm64 CPU hotspot into the smallest safe vectorized change. Preserve a portable production path and make every performance claim reproducible.

## Boundaries

- Match the user's authorization. For analysis or review, inspect and report without editing. For implementation, change only the selected hotspot, its build wiring, tests, and necessary documentation.
- Profile before optimizing. Source shape, an existing x86 SIMD path, or a compiler remark can suggest a candidate but cannot establish a bottleneck.
- Keep fact, inference, and unknown separate. Do not claim acceleration from successful compilation, SIMD mnemonics, HWCAP visibility, a microbenchmark alone, or emulation.
- Never apply `-march=native`, `+sve`, or `+sve2` to a distributable baseline target unless the declared deployment floor requires that ISA.
- Preserve the best existing fallback. A vector tier that is unavailable, slower, or fails verification must be removable or disableable without changing semantics.
- Treat Neon, SVE, SVE2, and SME as distinct contracts. Do not describe SVE1 code running on an SVE2 CPU as an SVE2 implementation.

## Choose the work mode

1. **Discover:** identify and rank measured vectorization candidates; stop with a recommendation and evidence unless implementation was requested.
2. **Implement:** establish a baseline, add one ISA tier or one compiler-vectorization change, and validate it before adding another tier.
3. **Review:** trace the changed kernel, build flags, dispatch, fallbacks, tests, and benchmark provenance. Report correctness or portability defects before speedups.

For C/C++ implementation or review, read [references/implementation-patterns.md](references/implementation-patterns.md). For correctness or performance work, read [references/validation-and-evidence.md](references/validation-and-evidence.md). Read [references/overlaybd-case-study.md](references/overlaybd-case-study.md) only when adapting or explaining the OverlayBD-derived pattern.

## Workflow and gates

### 1. Establish provenance and the real execution boundary

- Record repository revision, dirty-state boundary, target architecture, language, compiler and version, optimization/LTO flags, build type, and the actual runtime boundary: bare metal, container, VM, guest, or cross-build.
- Locate architecture-specific implementations, callers, tests, benchmarks, and build ownership. Prefer structural code tools for symbols/call paths and literal search for flags, macros, and logs.
- Run `scripts/probe-arm64-vector.sh` when C compiler and Linux HWCAP facts are useful. Its compile probes and runtime probes are separate evidence; neither substitutes for workload profiling.
- In a VM or container, make runtime decisions from the process that will execute the kernel. Host CPU features do not prove guest exposure.

### 2. Measure and rank candidates

- Reproduce the relevant workload and collect a profiler or trace baseline. Record raw output and the exact command.
- Rank by inclusive/self cost, call frequency, input sizes, and the fraction of end-to-end time affected. Use Amdahl's law to reject kernels whose maximum system impact is immaterial.
- Prefer dense, repeated work with independent lanes: comparisons, search/count/filter, reductions, transforms, codecs, checksums, parsing, and contiguous copies.
- Penalize pointer chasing, unpredictable branches, synchronization, syscalls, allocation, I/O waits, tiny cold loops, irregular gather/scatter, and semantics that forbid safe reassociation.
- Check optimized compiler output and vectorization diagnostics first. If auto-vectorization already produces an effective tier, improve source/alias information or keep it instead of duplicating it with intrinsics.

**Gate:** do not implement SIMD unless the hotspot is measured, its scalar semantics are explicit, and the expected system impact justifies the added maintenance surface.

### 3. Design the ISA ladder

Define the minimum useful ladder, normally `baseline -> Neon -> SVE`, adding SVE2 only for operations that use SVE2 instructions and show value.

- Compile baseline code for the project's supported Arm64 floor.
- For a broadly distributed Linux binary, gate ISA-dependent execution with symbolic `HWCAP_*`/`HWCAP2_*` constants or an established project CPU-feature library. A deployment contract may replace a runtime gate only when it is explicit and verified.
- Prefer a separate translation unit/object for SVE/SVE2. Apply feature flags only there, probe a real header and intrinsic at configure time, and keep a force-disable build option.
- Dispatch before any optional instruction executes. Watch for LTO, inlining, static initialization, and compiler-generated instructions that can leak a higher ISA into baseline code.
- Write SVE vector-length-agnostic loops using predicates and `svcnt*()` progress. Fix a vector length only when the complete deployment contract guarantees it and tests cover it.
- Cache dispatch when its cost matters, using the project's existing thread-safe initialization pattern.

**Gate:** the baseline artifact must build without optional headers/toolchain support and must start and run correctly on hardware where the optional HWCAP is absent.

### 4. Implement one variable at a time

- First preserve or create an independent scalar oracle that states exact comparison, overflow, floating-point, alignment, aliasing, tail, and empty-input behavior.
- Implement the narrowest tier. Keep data layout and public interfaces unchanged unless the measured bottleneck requires otherwise.
- For predicated SVE loads/stores, derive the predicate from the remaining logical elements; predication must prevent out-of-bounds access, not merely mask arithmetic.
- Reuse existing project dispatch and test seams. Do not create a second CPU-feature registry or a permanent public ABI solely for tests.
- Inspect the diff for newly duplicated state or parallel implementations without a platform reason.

### 5. Prove correctness, containment, and value

- Directly test every compiled kernel against the independent oracle, then test automatic dispatch and negative fallback behavior.
- Cover lane boundaries, tails, empty/small inputs, extremes, alignment, aliasing, and domain-specific cases. Use fixed seeds for reproducible randomized tests and fuzz/property testing where appropriate.
- Inspect the relevant objects and final artifact. Confirm optional instructions exist in the intended tier and do not appear in the baseline execution path.
- Run correctness on non-SVE Arm64, SVE1, and SVE2 targets when supported. Emulation is acceptable for compatibility/correctness, never for performance claims.
- Benchmark the best pre-change production path and each new tier on the same native machine, workload, binary policy, and controlled conditions. Retain all valid samples and failures.
- Re-run the end-to-end workload. Report kernel speedup and end-to-end impact separately; keep regressions and neutral results.

**Gate:** do not recommend enabling a tier by default until functional checks pass, unsupported-hardware fallback is proven, and native A/B evidence shows a worthwhile gain without material regression.

## Required result

Return a concise evidence ledger containing:

- scope, revision, and changed files or analysis boundary;
- measured hotspot and affected workload fraction;
- chosen ISA ladder and why rejected tiers were rejected;
- compiler/build probes versus runtime HWCAP facts;
- dispatch and baseline-containment proof;
- correctness matrix with per-target results;
- benchmark identity, raw-log locations, sample counts, failures, kernel results, and end-to-end results;
- verified facts, reasonable inferences, remaining unknowns, rollback/disable path, and recommendation.

If hardware, permissions, toolchains, raw baselines, or representative workloads are missing, stop at the strongest supported conclusion and name the exact next validation command or environment needed.
