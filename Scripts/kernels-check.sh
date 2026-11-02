#!/bin/bash
# Differentially checks every CAemiKernels kernel against its scalar reference: the codec and search harnesses (base64, hex,
# percent, find), the exhaustive ones (codec_exhaustive, kernels_exhaustive: every byte at every position, guard pages, every
# UTF-8 sequence, every date) under AddressSanitizer and UBSan, and every kernel from many threads under ThreadSanitizer; natively,
# then on an arm64 Mac as x86-64 under Rosetta 2, SSSE3 first and AVX2 when Rosetta advertises it. Before that, the libc-free
# codec kernels are compiled for Linux x86-64 and arm64. With --bench, reports the codec harnesses' throughput instead.
# `KERNELS="hex find"` limits it to some harnesses. Compiled with the package's strict C flags, as SwiftPM does.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
AEMI_ROOT="$root"
. "$root/Scripts/lib/c-targets.sh"

harnesses=${KERNELS:-"base64 hex percent find codec_exhaustive kernels_exhaustive"}
codec_kernels="base64 hex percent find"

build() { # build ARCH_FLAGS... ; produces $out/<harness> with sanitizers unless BENCH
    local flags=(${1+"$@"}) opt=-O1 san="-g -fsanitize=address,undefined -fno-sanitize-recover=all"
    [ "${BENCH:-}" = 1 ] && { opt=-O2; san=""; }
    local objects=""
    for source in $KERNELS_SOURCES $CPU_SOURCES; do
        # shellcheck disable=SC2086
        clang -Os $san ${flags[@]+"${flags[@]}"} $C_STRICT $C_INCLUDES -c "$source" -o "$out/k_$(basename "$source" .c).o"
        objects="$objects $out/k_$(basename "$source" .c).o"
    done
    for kernel in $harnesses; do
        # shellcheck disable=SC2086
        clang $opt $san ${flags[@]+"${flags[@]}"} $C_INCLUDES "$root/Benchmarks/CKernels/$kernel.c" $objects -o "$out/$kernel"
    done
}

# Every codec kernel compiles for Linux x86-64 (an SSE2 baseline, where a target-attribute mistake that macOS's SSSE3 baseline
# hides is an error) and Linux arm64, at -O0 and -O2, with the strict flags: the libc-free kernels need no Linux headers.
cross() {
    for target in x86_64-linux-gnu aarch64-linux-gnu; do
        for level in -O0 -O2; do
            for kernel in $codec_kernels; do
                # shellcheck disable=SC2086
                clang --target=$target -ffreestanding $level $C_STRICT $C_INCLUDES -c "$root/Sources/CAemiKernels/adf_$kernel.c" \
                    -o "$out/cross.o" || { echo "[FAIL] adf_$kernel.c for $target $level"; exit 1; }
            done
        done
    done
    echo "codec kernels compile for x86_64- and aarch64-linux-gnu at -O0 and -O2"
}

# Many threads from the first call on, under ThreadSanitizer (ARCH_FLAGS...).
threads() {
    local flags=(${1+"$@"})
    # shellcheck disable=SC2086
    # On Linux the swift.org clang's ThreadSanitizer runtime intercepts libdispatch, which it then needs at link time.
    local extra=""
    [ "$(uname -s)" = Linux ] && extra="-L/usr/lib/swift/linux -ldispatch -lBlocksRuntime -Wl,-rpath,/usr/lib/swift/linux"
    # shellcheck disable=SC2086
    clang -g -O1 -fsanitize=thread ${flags[@]+"${flags[@]}"} $C_INCLUDES "$root/Benchmarks/CKernels/codec_threads.c" $KERNELS_SOURCES \
        $CPU_SOURCES $extra -o "$out/threads"
}

# ThreadSanitizer cannot map its shadow memory in a translated Linux VM (x86-64 under Rosetta in a container): that is skipped,
# said so, and any other failure fails.
run_threads() {
    local log
    if log=$("$@" 2>&1); then
        echo "$log"
    elif echo "$log" | grep -q "memory layout is incompatible"; then
        echo "[SKIP] ThreadSanitizer cannot run in this translated environment"
    else
        echo "$log"
        return 1
    fi
}

if [ "${1:-}" = "--bench" ]; then
    harnesses=${harnesses/codec_exhaustive/}
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
    [ "$(uname -s)" = Darwin ] && cross
    build
    for kernel in $harnesses; do "$out/$kernel" --check; done
    if [ -z "${KERNELS:-}" ]; then threads && run_threads "$out/threads"; fi
    if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
        build -arch x86_64
        for kernel in $harnesses; do
            echo "x86-64 under Rosetta 2:"; arch -x86_64 "$out/$kernel" --check
            echo "x86-64 under Rosetta 2, AVX2 advertised:"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/$kernel" --check
        done
        if [ -z "${KERNELS:-}" ]; then
            threads -arch x86_64
            arch -x86_64 "$out/threads"
            ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$out/threads"
        fi
    fi
fi
