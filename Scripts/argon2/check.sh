#!/bin/sh
# The Argon2 kernels against their scalar references (kernels-check.c) with ASan and UBSan, natively and, on Apple silicon,
# as x86-64 under Rosetta (SSSE3, then AVX2 with ROSETTA_ADVERTISE_AVX=1).
# `--timing` runs timing-check.c instead, `--bench` bench.c. Exit 0 when every check agrees.
set -eu
cd "$(dirname "$0")"
AEMI_ROOT=$(cd ../.. && pwd)
. "$AEMI_ROOT/Scripts/lib/c-targets.sh"
OUT="${TMPDIR:-/tmp}/aemi-argon2-check"
CC="${CC:-cc}"
FILES="$ARGON2_SOURCES $CPU_SOURCES $CPU_TIMING"
# The kernels' own warnings are SwiftPM's (C_STRICT); the checks here are test programs, held to -Wall -Wextra -Werror.
FLAGS="-O2 -std=c11 -Wall -Wextra -Werror -Wno-missing-field-initializers $C_INCLUDES"
mkdir -p "$OUT"
if [ "${1:-}" = "--linux" ]; then
    # arm64 Linux in Apple's `container` (Alpine), with clang and GCC, with SHA3 asked at run time (getauxval) and given at
    # compile time: the paths macOS never builds.
    # shellcheck disable=SC2016 # the script is the container's, expanded there
    exec container run --rm -v "$AEMI_ROOT:/src" alpine:3.22 sh -c '
        set -eu
        apk add -q clang gcc musl-dev linux-headers >/dev/null
        for cc in clang gcc; do
            for march in "" "-march=armv8.4-a+sha3"; do
                echo "$cc ${march:-(SHA3 at run time)}:"
                CC="$cc" EXTRA_CFLAGS="$march" NO_SANITIZE=1 /src/Scripts/argon2/check.sh
            done
        done'
fi
if [ "${1:-}" = "--bench" ]; then
    # shellcheck disable=SC2086
    "$CC" -O3 $FLAGS -o "$OUT/bench" bench.c $FILES
    exec "$OUT/bench"
fi
if [ "${1:-}" = "--timing" ]; then
    # shellcheck disable=SC2086
    "$CC" -O3 $FLAGS -o "$OUT/timing" timing-check.c $FILES
    exec "$OUT/timing"
fi
SANITIZE="-fsanitize=address,undefined -fno-sanitize-recover=all"
[ -n "${NO_SANITIZE:-}" ] && SANITIZE=""
# shellcheck disable=SC2086
"$CC" $FLAGS ${EXTRA_CFLAGS:-} $SANITIZE -o "$OUT/check-host" kernels-check.c $FILES -lpthread
echo "host ($(uname -m))${SANITIZE:+, ASan+UBSan}:"; "$OUT/check-host"
# The published answers (RFC 7693, RFC 9106) and the secure helpers, independent of the scalar references.
# shellcheck disable=SC2086
"$CC" $FLAGS ${EXTRA_CFLAGS:-} $SANITIZE -o "$OUT/kat-host" kat-check.c $FILES -lpthread
"$OUT/kat-host"
if [ -z "${NO_SANITIZE:-}" ] && [ "$(uname -s)" = Darwin ]; then
    # The threaded fill under ThreadSanitizer: lanes filled by several threads must not race.
    # shellcheck disable=SC2086
    "$CC" $FLAGS -fsanitize=thread -o "$OUT/kat-threads" kat-check.c $FILES -lpthread
    echo "ThreadSanitizer:"; "$OUT/kat-threads"
fi
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
    # shellcheck disable=SC2086
    "$CC" $FLAGS -arch x86_64 -fsanitize=address,undefined -fno-sanitize-recover=all -o "$OUT/check-x86" kernels-check.c $FILES
    echo "x86_64 under Rosetta, ASan+UBSan:"; arch -x86_64 "$OUT/check-x86"
    # Rosetta runs AVX2 only when asked to advertise it.
    echo "x86_64 under Rosetta, AVX2 advertised:"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$OUT/check-x86"
    # shellcheck disable=SC2086
    "$CC" $FLAGS -arch x86_64 -fsanitize=address,undefined -fno-sanitize-recover=all -o "$OUT/kat-x86" kat-check.c $FILES
    arch -x86_64 "$OUT/kat-x86"
    ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$OUT/kat-x86"
fi
