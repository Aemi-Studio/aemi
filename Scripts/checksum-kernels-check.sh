#!/bin/sh
# ADR 0020's kernels against their scalar references, with ASan and UBSan, natively and (on Apple silicon) as x86-64 under
# Rosetta, which reports SSE4.2 so the `crc32` path runs. Exit 0 when every check agrees. `--bench` times them at -Os.
# `--linux` runs the check on arm64 Linux in Apple's `container` (Alpine), with clang and GCC, with and without the CRC, AES and
# SHA3 extensions on the command line: the runtime-dispatch path and the compile-time one, which macOS never builds.
set -eu
cd "$(dirname "$0")"
AEMI_ROOT=$(cd .. && pwd)
. "$AEMI_ROOT/Scripts/lib/c-targets.sh"
OUT="${TMPDIR:-/tmp}/aemi-checksum-kernels-check"
CC="${CC:-cc}"
KERNEL_FILES="$(kernels adf_crc32c adf_numeric adf_utf16 adf_cpu) $CPU_SOURCES"
FILES="checksum-kernels-check.c $KERNEL_FILES"
CHECK="-O2 -std=c11 -Wall -Wextra -Werror $C_INCLUDES"
SANITIZE="-fsanitize=address,undefined -fno-sanitize-recover=all"
mkdir -p "$OUT"
if [ "${1:-}" = "--linux" ]; then
    # shellcheck disable=SC2016 # the script is the container's, expanded there
    # The container sees the repository at /src, so the check runs there with the same script and no options.
    exec container run --rm -v "$AEMI_ROOT:/src" alpine:3.22 sh -c '
        set -eu
        apk add -q clang gcc musl-dev linux-headers >/dev/null
        for cc in clang gcc; do
            for march in "" "-march=armv8.2-a+crc+crypto+sha3"; do
                echo "$cc ${march:-(runtime dispatch)}:"
                CC="$cc" EXTRA_CFLAGS="$march" NO_SANITIZE=1 /src/Scripts/checksum-kernels-check.sh
            done
        done'
fi
if [ "${1:-}" = "--bench" ]; then
    # The flags a release build compiles the kernels with: -Os and the strict set from Package.swift.
    # shellcheck disable=SC2086
    "$CC" -Os $C_STRICT $C_INCLUDES -Wno-missing-prototypes -o "$OUT/bench" checksum-kernels-bench.c $KERNEL_FILES
    exec "$OUT/bench"
fi
[ -n "${NO_SANITIZE:-}" ] && SANITIZE=""
# shellcheck disable=SC2086
"$CC" $CHECK ${EXTRA_CFLAGS:-} $SANITIZE -o "$OUT/check-host" $FILES
echo "host ($(uname -m))${SANITIZE:+, ASan+UBSan}:"; "$OUT/check-host"
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
    # shellcheck disable=SC2086
    "$CC" $CHECK -arch x86_64 $SANITIZE -o "$OUT/check-x86" $FILES
    echo "x86_64 under Rosetta:"; arch -x86_64 "$OUT/check-x86"
fi
