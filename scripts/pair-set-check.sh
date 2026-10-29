#!/bin/sh
# Builds the pair-set (Teddy) kernel check for the host architecture and, on Apple silicon, also for x86_64 (run under Rosetta) so the
# SSSE3 path is exercised, with AddressSanitizer and UndefinedBehaviorSanitizer. Moved from AemiRegex with the kernel (ADR 0017).
# Exit status is the check's.
set -eu
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/aemi-pair-set-check"
SRC="../Sources/CAemiKernels"
mkdir -p "$OUT"
cc -O2 -std=c11 -I"$SRC/include" -fsanitize=address,undefined -o "$OUT/check-host" pair-set-check.c "$SRC/adf_teddy.c" "$SRC/adf_cpu.c"
echo "host ($(uname -m)), ASan+UBSan:"; "$OUT/check-host"
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
    cc -O2 -std=c11 -I"$SRC/include" -arch x86_64 -fsanitize=address,undefined -o "$OUT/check-x86" pair-set-check.c "$SRC/adf_teddy.c" \
        "$SRC/adf_cpu.c" 2>/dev/null \
        || cc -O2 -std=c11 -I"$SRC/include" -arch x86_64 -o "$OUT/check-x86" pair-set-check.c "$SRC/adf_teddy.c" "$SRC/adf_cpu.c"
    echo "x86_64 under Rosetta (SSSE3):"; arch -x86_64 "$OUT/check-x86"
fi
