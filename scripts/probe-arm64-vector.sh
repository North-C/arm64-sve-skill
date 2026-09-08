#!/usr/bin/env bash

set -u

usage() {
  printf '%s\n' \
    'Usage: ARM64_VECTOR_CC=<compiler> probe-arm64-vector.sh' \
    '' \
    'Compile-only probes test whether the selected compiler can build Neon,' \
    'SVE, and SVE2 code. On native Linux AArch64, a baseline helper also' \
    'reports current-process HWCAP and SVE vector-length facts.' \
    '' \
    'ARM64_VECTOR_CC must name one compiler executable or wrapper. It defaults' \
    'to cc. The script writes only to a private temporary directory.'
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

compiler=${ARM64_VECTOR_CC:-cc}
if ! command -v "$compiler" >/dev/null 2>&1; then
  printf 'error.compiler_not_found=%s\n' "$compiler" >&2
  exit 2
fi

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/arm64-vector-probe.XXXXXX") || exit 2
cleanup() {
  if [[ -f "$probe_dir/probe.o" ]]; then
    unlink "$probe_dir/probe.o"
  fi
  if [[ -f "$probe_dir/runtime-probe" ]]; then
    unlink "$probe_dir/runtime-probe"
  fi
  rmdir -- "$probe_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

probe_compile() {
  probe_flag=$1
  probe_source=$2
  if printf '%s\n' "$probe_source" | \
      "$compiler" -std=c11 -Werror "$probe_flag" -x c -c -o "$probe_dir/probe.o" - \
        >/dev/null 2>&1; then
    printf '%s' yes
  else
    printf '%s' no
  fi
  if [[ -f "$probe_dir/probe.o" ]]; then
    unlink "$probe_dir/probe.o"
  fi
}

compiler_path=$(command -v "$compiler")
compiler_target=$("$compiler" -dumpmachine 2>/dev/null || printf '%s' unknown)
compiler_version=$("$compiler" --version 2>/dev/null | sed -n '1p')

neon_source='#include <arm_neon.h>
#include <stdint.h>
uint32_t probe(const uint32_t *p) {
  uint32x4_t v = vld1q_u32(p);
  return vaddvq_u32(v);
}'

sve_source='#include <arm_sve.h>
#include <stdint.h>
#ifndef __ARM_FEATURE_SVE
#error SVE feature macro missing
#endif
uint32_t probe(const uint32_t *p, uint64_t n) {
  svbool_t pg = svwhilelt_b32((uint64_t)0, n);
  return svaddv_u32(pg, svld1_u32(pg, p));
}'

sve2_source='#include <arm_sve.h>
#include <stdint.h>
#ifndef __ARM_FEATURE_SVE2
#error SVE2 feature macro missing
#endif
uint64_t probe(const uint8_t *p) {
  svbool_t pg = svwhilelt_b8((uint64_t)0, (uint64_t)16);
  svuint8_t v = svld1_u8(pg, p);
  return svcntp_b8(pg, svmatch_u8(pg, v, v));
}'

printf 'compiler.path=%s\n' "$compiler_path"
printf 'compiler.target=%s\n' "$compiler_target"
printf 'compiler.version=%s\n' "$compiler_version"
printf 'compile.neon=%s\n' "$(probe_compile -march=armv8-a+simd "$neon_source")"
printf 'compile.sve=%s\n' "$(probe_compile -march=armv8.2-a+sve "$sve_source")"
printf 'compile.sve2=%s\n' "$(probe_compile -march=armv9-a+sve2 "$sve2_source")"

runtime_os=$(uname -s 2>/dev/null || printf '%s' unknown)
runtime_arch=$(uname -m 2>/dev/null || printf '%s' unknown)
printf 'runtime.os=%s\n' "$runtime_os"
printf 'runtime.arch=%s\n' "$runtime_arch"

if [[ "$runtime_os" != Linux || ! "$runtime_arch" =~ ^(aarch64|arm64)$ ]]; then
  printf '%s\n' 'runtime.probe=skipped_non_linux_aarch64'
  exit 0
fi

runtime_source='#include <asm/hwcap.h>
#include <stdio.h>
#include <sys/auxv.h>
#include <sys/prctl.h>
#include <linux/prctl.h>

int main(void) {
  const unsigned long hwcap = getauxval(AT_HWCAP);
  printf("runtime.hwcap=0x%lx\n", hwcap);
#ifdef HWCAP_ASIMD
  printf("runtime.neon=%s\n", (hwcap & HWCAP_ASIMD) ? "yes" : "no");
#else
  printf("runtime.neon=unknown_header_missing\n");
#endif
#ifdef HWCAP_SVE
  const int have_sve = (hwcap & HWCAP_SVE) != 0;
  printf("runtime.sve=%s\n", have_sve ? "yes" : "no");
#else
  const int have_sve = 0;
  printf("runtime.sve=unknown_header_missing\n");
#endif
#if defined(AT_HWCAP2) && defined(HWCAP2_SVE2)
  const unsigned long hwcap2 = getauxval(AT_HWCAP2);
  printf("runtime.hwcap2=0x%lx\n", hwcap2);
  printf("runtime.sve2=%s\n", (hwcap2 & HWCAP2_SVE2) ? "yes" : "no");
#else
  printf("runtime.sve2=unknown_header_missing\n");
#endif
#if defined(PR_SVE_GET_VL) && defined(PR_SVE_VL_LEN_MASK)
  if (have_sve) {
    const int vl = prctl(PR_SVE_GET_VL);
    if (vl >= 0)
      printf("runtime.sve_vl_bytes=%d\n", vl & PR_SVE_VL_LEN_MASK);
    else
      printf("runtime.sve_vl_bytes=prctl_failed\n");
  } else {
    printf("runtime.sve_vl_bytes=not_available\n");
  }
#else
  printf("runtime.sve_vl_bytes=unknown_header_missing\n");
#endif
  return 0;
}'

if printf '%s\n' "$runtime_source" | \
    "$compiler" -std=c11 -Werror -x c -o "$probe_dir/runtime-probe" - \
      >/dev/null 2>&1; then
  runtime_output=$("$probe_dir/runtime-probe" 2>/dev/null)
  runtime_rc=$?
  if [[ "$runtime_rc" -eq 0 ]]; then
    printf '%s\n' 'runtime.probe=executed'
    printf '%s\n' "$runtime_output"
  else
    printf 'runtime.probe=execution_failed_%d\n' "$runtime_rc"
  fi
else
  printf '%s\n' 'runtime.probe=compile_failed'
fi
