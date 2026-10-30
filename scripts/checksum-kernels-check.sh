#!/bin/sh
# ADR 0020's kernels against their scalar references, with ASan and UBSan, natively and (on Apple silicon) as x86-64 under
# Rosetta, which reports SSE4.2 so the `crc32` path runs. Exit 0 when every check agrees. `--bench` times them at -Os.
# `--linux` runs the check on arm64 Linux in Apple's `container` (Alpine), with clang and GCC, with and without the CRC, AES and
# SHA3 extensions on the command line: the runtime-dispatch path and the compile-time one, which macOS never builds.
set -eu
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/aemi-checksum-kernels-check"
SRC="../Sources/CAemiKernels"
FILES="checksum-kernels-check.c $SRC/adf_crc32c.c $SRC/adf_numeric.c $SRC/adf_utf16.c $SRC/adf_cpu.c"
mkdir -p "$OUT"
if [ "${1:-}" = "--linux" ]; then
    # shellcheck disable=SC2016
    exec container run --rm -v "$(cd .. && pwd):/src" alpine:3.22 sh -c '
        set -eu
        apk add -q clang gcc musl-dev linux-headers >/dev/null
        cd /src/scripts
        SRC=../Sources/CAemiKernels
        for cc in clang gcc; do
            for march in "" "-march=armv8.2-a+crc+crypto+sha3"; do
                echo "$cc ${march:-(runtime dispatch)}:"
                # shellcheck disable=SC2086
                $cc -O2 $march -std=c11 -Wall -Wextra -Werror -I$SRC/include -o /tmp/check checksum-kernels-check.c \
                    $SRC/adf_crc32c.c $SRC/adf_numeric.c $SRC/adf_utf16.c $SRC/adf_cpu.c
                /tmp/check
            done
        done'
fi
if [ "${1:-}" = "--bench" ]; then
    # The flags a release build compiles the kernels with: -Os and the strict set from Package.swift.
    strict=$(sed -n '/^let strictCSettings/,/^]/p' ../Package.swift | grep -o '"-[^"]*"' | tr -d '"' | tr '\n' ' ')
    # shellcheck disable=SC2086
    cc -Os $strict -I"$SRC/include" -o "$OUT/bench" checksum-kernels-bench.c "$SRC/adf_crc32c.c" "$SRC/adf_numeric.c" \
        "$SRC/adf_utf16.c" "$SRC/adf_cpu.c" -Wno-missing-prototypes
    "$OUT/bench"
    exit 0
fi
# shellcheck disable=SC2086
"${CC:-cc}" -O2 -std=c11 -Wall -Wextra -Werror -I"$SRC/include" -fsanitize=address,undefined -fno-sanitize-recover=all -o "$OUT/check-host" $FILES
echo "host ($(uname -m)), ASan+UBSan:"; "$OUT/check-host"
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
    # shellcheck disable=SC2086
    cc -O2 -std=c11 -I"$SRC/include" -arch x86_64 -fsanitize=address,undefined -fno-sanitize-recover=all -o "$OUT/check-x86" $FILES 2>/dev/null \
        || cc -O2 -std=c11 -I"$SRC/include" -arch x86_64 -o "$OUT/check-x86" $FILES
    echo "x86_64 under Rosetta:"; arch -x86_64 "$OUT/check-x86"
fi
