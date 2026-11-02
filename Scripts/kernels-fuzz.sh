#!/bin/bash
# libFuzzer over every C kernel: the codecs and search (Benchmarks/CKernels/codec_fuzz.c), the scanners, folding, UTF-8 and
# UTF-16, checksums, counts, sets and dates (kernels_fuzz.c), and the cryptographic kernels (Scripts/argon2/fuzz.c), with
# AddressSanitizer and UBSan: natively, then on an arm64 Mac as x86-64 under Rosetta 2, SSSE3 first and AVX2 when Rosetta
# advertises it.
#
#   Scripts/kernels-fuzz.sh [SECONDS] [TARGET...]   each run lasts SECONDS (default 60); TARGET: codec, kernels, crypto
#
# Needs a clang with libFuzzer: a swift.org toolchain's (Xcode's has none), found under ~/Library/Developer/Toolchains or given as
# FUZZ_CLANG. The corpora are kept in ${KERNELS_FUZZ_CORPUS:-$TMPDIR/aemi-kernels-fuzz}/<target> between runs. A finding stops the run and leaves
# its input as crash-* in the current directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
seconds=${1:-60}
AEMI_ROOT="$root"
. "$root/Scripts/lib/c-targets.sh"
clang=${FUZZ_CLANG:-$(ls -d "$HOME"/Library/Developer/Toolchains/swift-*.xctoolchain/usr/bin/clang 2>/dev/null | sort -V | tail -1)}
clang=$(command -v "$clang" || true)
[ -x "$clang" ] || { echo "[FAIL] no clang with libFuzzer: set FUZZ_CLANG"; exit 2; }
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
shift || true
targets=${*:-codec kernels crypto}
corpora=${KERNELS_FUZZ_CORPUS:-${TMPDIR:-/tmp}/aemi-kernels-fuzz}
build() { # TARGET ARCH
    local sysroot=() sources
    [ "$(uname -s)" = Darwin ] && sysroot=(-isysroot "$(xcrun --show-sdk-path)" -arch "$2")
    case $1 in
        codec) sources="$root/Benchmarks/CKernels/codec_fuzz.c $KERNELS_SOURCES" ;;
        kernels) sources="$root/Benchmarks/CKernels/kernels_fuzz.c $KERNELS_SOURCES" ;;
        crypto) sources="$root/Scripts/argon2/fuzz.c $ARGON2_SOURCES $CPU_TIMING" ;;
    esac
    # shellcheck disable=SC2086
    "$clang" "${sysroot[@]}" -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all $C_INCLUDES \
        $sources $CPU_SOURCES -o "$out/fuzz-$1-$2"
}
run() { # TARGET LABEL BINARY...
    local target=$1 label=$2
    shift 2
    mkdir -p "$corpora/$target"
    echo "== $target, $label, ${seconds}s"
    "$@" -max_total_time="$seconds" -max_len=4096 -print_final_stats=1 "$corpora/$target" 2>&1 \
        | grep -E "stat::number_of_executed_units|ERROR|SUMMARY|crash-|Done" || true
}
native=$(uname -m)
for target in $targets; do
    build "$target" "$native"
    run "$target" "$native" "$out/fuzz-$target-$native"
    if [ "$(uname -s)-$native" = "Darwin-arm64" ]; then
        build "$target" x86_64
        run "$target" "x86-64 under Rosetta 2 (SSSE3)" arch -x86_64 "$out/fuzz-$target-x86_64"
        run "$target" "x86-64 under Rosetta 2 (AVX2)" env ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/fuzz-$target-x86_64"
    fi
done
ls crash-* >/dev/null 2>&1 && { echo "[FAIL] a finding: see crash-* here"; exit 1; }
echo "[OK] no finding"
