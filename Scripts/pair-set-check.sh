#!/bin/sh
# Builds the pair-set (Teddy) kernel check for the host architecture and, on Apple silicon, also for x86_64 (run under Rosetta) so the
# SSSE3 path is exercised, with AddressSanitizer and UndefinedBehaviorSanitizer. Moved from AemiRegex with the kernel (ADR 0018).
# Exit status is the check's.
set -eu
cd "$(dirname "$0")"
AEMI_ROOT=$(cd .. && pwd)
. "$AEMI_ROOT/Scripts/lib/c-targets.sh"
OUT="${TMPDIR:-/tmp}/aemi-pair-set-check"
CC="${CC:-cc}"
KERNEL_FILES="$(kernels adf_teddy adf_cpu) $CPU_SOURCES"
FILES="pair-set-check.c $KERNEL_FILES"
CHECK="-O2 -std=c11 -Wall -Wextra -Werror $C_INCLUDES -fsanitize=address,undefined -fno-sanitize-recover=all"
mkdir -p "$OUT"
# shellcheck disable=SC2086
"$CC" $CHECK -o "$OUT/check-host" $FILES
echo "host ($(uname -m)), ASan+UBSan:"; "$OUT/check-host"
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
    # shellcheck disable=SC2086
    "$CC" $CHECK -arch x86_64 -o "$OUT/check-x86" $FILES
    echo "x86_64 under Rosetta:"; arch -x86_64 "$OUT/check-x86"
    # Rosetta runs AVX2 only when asked to advertise it.
    echo "x86_64 under Rosetta, AVX2 advertised:"; ROSETTA_ADVERTISE_AVX=1 arch -x86_64 "$OUT/check-x86"
fi
