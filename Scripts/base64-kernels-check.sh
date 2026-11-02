#!/bin/bash
# Differentially checks CAemiKernels' Base64 block kernels against their scalar references on exact-size buffers under
# AddressSanitizer and UBSan: native, then (on an arm64 Mac) x86-64 under Rosetta 2, SSSE3 first and AVX2 when Rosetta
# advertises it. With --bench, reports throughput instead (native, and x86-64 when run as `arch -x86_64`).
# Compiled with the package's strict C flags, as SwiftPM does.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
AEMI_ROOT="$root"
. "$root/Scripts/lib/c-targets.sh"

build() { # build ARCH_FLAGS... ; produces $out/b with sanitizers unless BENCH
    local flags=(${1+"$@"}) opt=-O1 san="-g -fsanitize=address,undefined -fno-sanitize-recover=all"
    [ "${BENCH:-}" = 1 ] && { opt=-O2; san=""; }
    # shellcheck disable=SC2086
    clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c "$root/Sources/CAemiKernels/adf_base64.c" -o "$out/k.o"
    # shellcheck disable=SC2086
    clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c "$root/Sources/CAemiKernels/adf_cpu.c" -o "$out/cpu.o"
    # shellcheck disable=SC2086
    clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c $CPU_SOURCES -o "$out/features.o"
    # shellcheck disable=SC2086
    clang $opt $san ${flags[@]+"${flags[@]}"} $C_INCLUDES "$root/Benchmarks/CKernels/base64.c" "$out/k.o" "$out/cpu.o" "$out/features.o" -o "$out/b"
}

if [ "${1:-}" = "--bench" ]; then
    BENCH=1 build
    "$out/b"
    if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
        BENCH=1 build -arch x86_64
        echo "x86-64 under Rosetta 2 (SSSE3):"; arch -x86_64 "$out/b"
        echo "x86-64 under Rosetta 2 (AVX2 advertised):"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/b"
    fi
else
    build
    "$out/b" --check
    if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
        build -arch x86_64
        echo "x86-64 under Rosetta 2:"; arch -x86_64 "$out/b" --check
        echo "x86-64 under Rosetta 2, AVX2 advertised:"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/b" --check
    fi
fi
