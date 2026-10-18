#!/bin/bash
# Benchmarks (default) or differentially checks (--check) CAemiKernels' fold_ascii and index_of_nonascii.
#
# The kernels are compiled exactly as SwiftPM compiles the CAemiKernels target in release: -Os (read
# from the build's response file on 2026-10-18) plus the package's strict C settings, parsed from
# Package.swift so this script cannot drift from them. Baselines are the scalar references in their
# own translation units at -Os, -O2, and -O2 without vectorization; the previous NEON kernel, from
# 3e64286's parent, is rebuilt from git. --check builds everything with AddressSanitizer and UBSan.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
kernels="$root/Sources/CAemiKernels"

strict=$(sed -n '/^let strictCSettings/,/^]/p' "$root/Package.swift" | grep -o '"-[^"]*"' | tr -d '"' | tr '\n' ' ')
[ -n "$strict" ] || { echo "could not read strictCSettings from Package.swift" >&2; exit 1; }

mode=bench
extra=""
if [ "${1:-}" = "--check" ]; then
    mode=check
    extra="-g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
fi

cc() { clang -c $extra "$@"; }
for source in "$kernels"/*.c; do
    # shellcheck disable=SC2086
    cc -Os $strict -I"$kernels/include" "$source" -o "$out/$(basename "$source" .c).o"
done
git -C "$root" show '3e64286^:Sources/CAemiKernels/adf_fold.c' | sed 's/adf_fold_ascii/prev_fold_ascii/g' > "$out/prev_fold.c"
cc -Os -std=c11 -I"$kernels/include" "$out/prev_fold.c" -o "$out/prev_fold.o"
cc -Os -std=c11 -DVARIANT=Os "$root/Benchmarks/CKernels/scalar_ref.c" -o "$out/ref_Os.o"
cc -O2 -std=c11 -DVARIANT=O2 "$root/Benchmarks/CKernels/scalar_ref.c" -o "$out/ref_O2.o"
cc -O2 -fno-vectorize -fno-slp-vectorize -std=c11 -DVARIANT=O2_novec "$root/Benchmarks/CKernels/scalar_ref.c" -o "$out/ref_O2_novec.o"
cc -O2 -std=c11 -I"$kernels/include" "$root/Benchmarks/CKernels/harness.c" -o "$out/harness.o"
# shellcheck disable=SC2086
clang $extra "$out"/*.o -o "$out/bench-c-kernels"

if [ "$mode" = check ]; then
    "$out/bench-c-kernels" --check
else
    "$out/bench-c-kernels"
fi
