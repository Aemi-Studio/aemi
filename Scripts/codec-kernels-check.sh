#!/bin/bash
# Differentially checks CAemiKernels' codec and search kernels (Base64, hex, percent-coding, byte-string search) against their scalar references on
# exact-size buffers under AddressSanitizer and UBSan: native, then (on an arm64 Mac) x86-64 under Rosetta 2, SSSE3 first and AVX2
# when Rosetta advertises it. With --bench, reports throughput instead. `KERNELS="hex"` limits it to some harnesses.
# Compiled with the package's strict C flags, as SwiftPM does.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
AEMI_ROOT="$root"
. "$root/Scripts/lib/c-targets.sh"

harnesses=${KERNELS:-"base64 hex percent find"}

build() { # build ARCH_FLAGS... ; produces $out/<harness> with sanitizers unless BENCH
    local flags=(${1+"$@"}) opt=-O1 san="-g -fsanitize=address,undefined -fno-sanitize-recover=all"
    [ "${BENCH:-}" = 1 ] && { opt=-O2; san=""; }
    # shellcheck disable=SC2086
    for kernel in $harnesses; do
        # shellcheck disable=SC2086
        clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c "$root/Sources/CAemiKernels/adf_$kernel.c" -o "$out/k_$kernel.o"
    done
    # shellcheck disable=SC2086
    clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c "$root/Sources/CAemiKernels/adf_cpu.c" -o "$out/cpu.o"
    # shellcheck disable=SC2086
    clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c $CPU_SOURCES -o "$out/features.o"
    # shellcheck disable=SC2086
    for kernel in $harnesses; do
        # shellcheck disable=SC2086
        clang $opt $san ${flags[@]+"${flags[@]}"} $C_INCLUDES "$root/Benchmarks/CKernels/$kernel.c" "$out/k_$kernel.o" "$out/cpu.o" \
            "$out/features.o" -o "$out/$kernel"
    done
}

if [ "${1:-}" = "--bench" ]; then
    BENCH=1 build
    for kernel in $harnesses; do "$out/$kernel"; done
    if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
        BENCH=1 build -arch x86_64
        for kernel in $harnesses; do
            echo "x86-64 under Rosetta 2 (SSSE3):"; arch -x86_64 "$out/$kernel"
            echo "x86-64 under Rosetta 2 (AVX2 advertised):"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/$kernel"
        done
    fi
else
    build
    for kernel in $harnesses; do "$out/$kernel" --check; done
    if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
        build -arch x86_64
        for kernel in $harnesses; do
            echo "x86-64 under Rosetta 2:"; arch -x86_64 "$out/$kernel" --check
            echo "x86-64 under Rosetta 2, AVX2 advertised:"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/$kernel" --check
        done
    fi
fi
