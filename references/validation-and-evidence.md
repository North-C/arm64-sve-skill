# Validation and evidence

Read this reference before claiming correctness, compatibility, or performance.

## Three independent claims

Keep these claims separate:

1. **Toolchain containment:** the build can create the optional object while the distributable baseline remains compatible.
2. **Functional correctness:** each kernel and runtime dispatch preserve semantics across supported inputs and targets.
3. **Performance value:** the vector tier improves the selected native workload enough to justify its cost.

Passing one does not imply another.

## Minimum compatibility matrix

Adapt the matrix to the project's actual support policy and report every cell as pass, fail, skipped with reason, or not run.

| Target | Build | Start/fallback | Direct kernel correctness | Dispatch | Native performance |
| --- | --- | --- | --- | --- | --- |
| non-Arm CI | baseline; optional TUs excluded | N/A | architecture tests visibly skipped | N/A | N/A |
| Arm64 without SVE | baseline + Neon as supported | must not execute SVE | baseline/Neon | lower tier selected | optional Neon A/B |
| Arm64 SVE1 | SVE object included | yes | baseline/Neon/SVE | SVE selected | required for SVE claim |
| Arm64 SVE2 | SVE1 and optional real SVE2 object | yes | all compiled tiers | highest valid tier | required for SVE2 claim |
| old/minimum toolchain | optional object disabled if unsupported | baseline works | baseline tests | baseline/lower tier | N/A |

For VMs, include guest kernel/VMM CPU configuration and facts observed inside the guest. For cross-builds, separate builder identity from execution-target identity.

## Correctness design

Use an independent scalar oracle written from the semantic contract, not a helper shared with the vector implementation. Directly invoke every compiled tier so an incorrect kernel cannot hide behind dispatch.

Select cases relevant to the operation:

- zero, one, and small lengths;
- lengths immediately below, equal to, and above Neon lane groups and every observed SVE vector length;
- unaligned addresses and legal alias/overlap patterns;
- minimum/maximum integers, signed transitions, carries, saturation, and reduction overflow;
- exact-hit, no-hit, all-hit, sorted, repeated, and adversarial distributions for search/filter kernels;
- NaN, infinities, signed zero, subnormals, rounding, and reassociation policy for floating point;
- fixed-seed randomized/property tests and fuzzing for parsers or externally controlled data;
- concurrent first-use when dispatch initialization is shared.

Run sanitizers supported by the project. Predicated loads still require a correct predicate and valid base pointer. Inspect failures instead of treating a retry as a pass.

Test automatic selection separately from direct kernels:

- log or expose the selected tier through an existing diagnostic seam;
- prove SVE is not selected without `HWCAP_SVE`;
- prove SVE2 is not selected without both a compiled SVE2 implementation and `HWCAP2_SVE2`;
- prove the application starts and completes a representative operation on an unsupported machine;
- verify a disable/rollback switch selects the lower tier.

## Artifact inspection

Inspect per-tier objects and the linked artifact with the target-aware `objdump`/`llvm-objdump`, `readelf`, and symbol tools available in the project.

Record:

- compiler command/compile database entry for every tier;
- disassembly around the kernel and dispatch;
- evidence that intended Neon/SVE/SVE2 instructions are present;
- evidence that optional instructions are not reachable before the runtime gate;
- LTO/inlining status and symbol placement;
- dynamic loader and architecture identity when packaging or cross-building.

Do not infer final binary compatibility from source macros or object flags alone.

## Benchmark protocol

Maintain two scalar concepts when needed:

- an **oracle scalar** optimized for clarity and independence;
- the **best pre-change production path**, compiled under normal production flags, used as the performance baseline.

Prevent dead-code elimination and validate benchmark results during the run. Inspect the baseline disassembly: a “scalar” benchmark silently auto-vectorized by the compiler is not a scalar-kernel comparison, though it may still be the correct production baseline.

Capture the following identity with raw logs:

- commit/diff and dirty boundary;
- CPU model, topology, current-process HWCAP/HWCAP2, microcode/firmware if relevant;
- OS/kernel, bare-metal/container/VM identity, and guest CPU exposure;
- compiler/linker versions and exact flags, including LTO and vector-length policy;
- selected runtime tier and SVE vector length for each run;
- workload/data identity, input sizes/distribution, thread count, affinity/NUMA placement;
- governor/frequency policy, competing load, warm-up, cooldown, run order, and repetition count.

Use the same machine and controlled conditions for all tiers. Randomize or alternate run order when drift is plausible. Keep per-run values, errors, timeouts, and exclusions; state the complete denominator. Choose summary statistics appropriate to the metric and include uncertainty, not only the best sample.

Measure both:

- **kernel/microbenchmark:** cycles or time per operation, throughput, and useful counters such as instructions, branches, cache/TLB misses, and memory bandwidth;
- **representative end to end:** user-visible latency/throughput/resource cost with the same workload and success criteria.

Use the measured affected fraction `p` and kernel speedup `s` as a sanity check:

```text
maximum expected overall speedup = 1 / ((1 - p) + p / s)
```

If observed end-to-end movement is inconsistent with this bound, investigate workload drift, measurement error, or effects outside the selected kernel.

QEMU or another emulator can expand functional coverage across vector lengths and feature combinations. It cannot establish native latency, throughput, or energy value.

## Decision record template

```text
Scope/revision:
Request mode: discover | implement | review
Workload and raw baseline:
Measured hotspot and affected fraction:
Semantic contract:
Candidate assessment:
ISA ladder and rejected tiers:
Build probes:
Runtime HWCAP facts:
Containment/disassembly evidence:
Correctness matrix:
Benchmark identity and raw logs:
Kernel result:
End-to-end result:
Failures/exclusions/denominator:
Rollback or disable path:
Verified facts:
Inferences:
Unknowns and next validation:
Recommendation:
```

Recommend default enablement only when the evidence supports the project's compatibility and maintenance policy. A correct neutral result is a valid reason to keep the code experimental or remove it.
