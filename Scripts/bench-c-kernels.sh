#!/bin/bash
# Benchmarks (default), benchmarks the small-input scanners (--small) or differentially checks (--check) CAemiKernels'
# fold_ascii, index_of_nonascii and the other byte scanners.
#
# The kernels are compiled exactly as SwiftPM compiles the CAemiKernels target in release: -Os (read
# from the build's response file on 2026-10-18) plus the package's strict C settings, parsed from
# Package.swift so this script cannot drift from them. Baselines are the scalar references in their
# own translation units at -Os, -O2, and -O2 without vectorization; the previous NEON kernel, from
# aff9ca5's parent, is rebuilt from git. --check builds everything with AddressSanitizer and UBSan.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
kernels="$root/Sources/CAemiKernels"
AEMI_ROOT="$root"
. "$root/Scripts/lib/c-targets.sh"

mode=bench
extra=""
if [ "${1:-}" = "--check" ]; then
    mode=check
    extra="-g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
    # The x86-64 pass (below) rebuilds everything for x86_64 and runs it under Rosetta.
    [ -n "${AEMI_X86:-}" ] && extra="$extra -arch x86_64"
elif [ "${1:-}" = "--small" ]; then
    mode=small
fi

# shellcheck disable=SC2086 # $extra is a list of flags
cc() { clang -c $extra "$@"; }
# CAemiKernels and the feature set it dispatches on (CAemiCPU), as SwiftPM compiles them.
for source in $KERNELS_SOURCES $CPU_SOURCES; do
    # shellcheck disable=SC2086
    cc -Os $C_STRICT $C_INCLUDES "$source" -o "$out/$(basename "$source" .c).o"
done
git -C "$root" show 'aff9ca5^:Sources/CAemiKernels/adf_fold.c' | sed 's/adf_fold_ascii/prev_fold_ascii/g' > "$out/prev_fold.c"
cc -Os -std=c11 -I"$kernels/include" "$out/prev_fold.c" -o "$out/prev_fold.o"
# The scanners as they were before the small-input work (SMALL_BASE), under other names: "before" in --small.
SMALL_BASE=5ee18dc^
git -C "$root" show "$SMALL_BASE:Sources/CAemiKernels/adf_scan.c" | sed 's/adf_index_of/prev_index_of/g; s/adf_first_/prev_first_/g' > "$out/prev_scan.c"
cc -Os -std=c11 -I"$kernels/include" "$out/prev_scan.c" -o "$out/prev_scan.o"
cc -O2 -std=c11 -I"$kernels/include" "$root/Benchmarks/CKernels/small_inputs.c" -o "$out/small_inputs.o"
cc -Os -std=c11 -DVARIANT=Os "$root/Benchmarks/CKernels/scalar_ref.c" -o "$out/ref_Os.o"
cc -O2 -std=c11 -DVARIANT=O2 "$root/Benchmarks/CKernels/scalar_ref.c" -o "$out/ref_O2.o"
cc -O2 -fno-vectorize -fno-slp-vectorize -std=c11 -DVARIANT=O2_novec "$root/Benchmarks/CKernels/scalar_ref.c" -o "$out/ref_O2_novec.o"
cc -O2 -std=c11 -I"$kernels/include" "$root/Benchmarks/CKernels/harness.c" -o "$out/harness.o"
# shellcheck disable=SC2086
clang $extra "$out"/*.o -o "$out/bench-c-kernels"

if [ "$mode" = check ] && [ -n "${AEMI_X86:-}" ]; then
    # Rosetta runs AVX2 only when asked to advertise it: SSE4.2 first, then AVX2.
    echo "x86_64 under Rosetta:"; arch -x86_64 "$out/bench-c-kernels" --check
    echo "x86_64 under Rosetta, AVX2 advertised:"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/bench-c-kernels" --check
elif [ "$mode" = check ]; then
    "$out/bench-c-kernels" --check
    if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
        AEMI_X86=1 bash "$0" --check
    fi
elif [ "$mode" = small ]; then
    "$out/bench-c-kernels" --small
else
    "$out/bench-c-kernels"
fi
