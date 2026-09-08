# OverlayBD LSMT case study

This is a dated source-derived example, not a universal implementation recipe.

## Provenance

- Source: containerd/overlaybd pull request [#452](https://github.com/containerd/overlaybd/pull/452), opened 2026-09-06 from `youhangwang:sve`.
- Reviewed patch commits: `d482438be6c816cc0a8581e151a476c4b9d88051` and `518f4eb38f9f070db03f79ae5fde61e22ac56bc4` as exposed by the PR patch on 2026-09-08.
- The PR was open when reviewed. Treat later merge status and code as unknown until refreshed.

## What the patch establishes

The LSMT linearized B+tree inner search already had an x86_64 AVX-512 specialization. The patch uses that architecture seam to add:

- Neon kernels for the fixed node shapes of sixteen `uint32_t` keys and eight `uint64_t` keys;
- an SVE1 vector-length-agnostic implementation in a separate `index_sve.cpp` translation unit;
- a CMake flag probe plus an `<arm_sve.h>` intrinsic compilation probe before adding the SVE source;
- `-march=armv8.2-a+sve` only on the SVE translation unit and a force-disable option;
- runtime SVE selection from `getauxval(AT_HWCAP)` before calling the SVE bridge;
- direct kernel tests against an independent scalar reference with boundary values, exact hits, fixed-seed random data, and 4096 trials;
- an explicit skip for SVE tests when the executing machine does not expose SVE.

The SVE loop uses `svwhilelt` predicates and advances by `svcntw()`/`svcntd()`, so its source does not assume a fixed vector length.

## Performance statement and evidence boundary

The PR description reports a single-thread microbenchmark over working sets from L1 size through 256 MB:

- `u32`/16-key kernel: about 1.9–2.7x for Neon and 2.1–2.7x for SVE versus scalar;
- `u64`/8-key kernel: about 1.2–1.7x for Neon and 1.5–1.7x for SVE versus scalar.

Those figures are author-reported in the PR description. The reviewed patch does not contain the benchmark harness, raw samples, CPU/compiler identity, SVE vector length, run denominator, or an end-to-end OverlayBD result. They motivate the optimization but are not independently reproducible performance proof.

## Reusable decisions

1. Start from a measured, repeated fixed-shape kernel and an existing architecture specialization seam.
2. Keep optional scalable-vector code in an ISA-specific object rather than raising the whole binary's architecture floor.
3. Require both toolchain support and runtime feature exposure.
4. Use vector-length-agnostic predication for portable SVE1.
5. Directly cross-check every kernel against a separate semantic oracle.
6. Preserve a lower tier for unsupported hardware and toolchains.
7. Separate kernel speedup from system performance until an end-to-end A/B is available.

## Caveats to improve when generalizing

- Prefer symbolic `HWCAP_SVE`, `HWCAP_ASIMD`, and `HWCAP2_SVE2` definitions from platform headers or the project's feature library instead of numeric bit shifts.
- If the SVE object contains only SVE1 instructions, report the selected implementation as SVE even when the CPU also advertises SVE2. Add an SVE2 tier only for SVE2-specific code with its own gate and benchmark.
- Do not assume Neon availability solely from `__aarch64__` for a broadly portable userspace binary; either gate `HWCAP_ASIMD` or state and verify the deployment ABI contract.
- Add dispatch-level integration tests, unsupported-hardware start/fallback tests, object/final-binary disassembly checks, and LTO containment checks.
- Preserve the benchmark harness and raw evidence, then measure a representative OverlayBD workload to establish system impact.

These caveats are improvements to the generalized skill. They do not assert that the open PR is incorrect in its intended deployment environment, which was not fully specified in the reviewed patch.
