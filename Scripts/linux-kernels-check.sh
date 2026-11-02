#!/bin/bash
# Every C kernel check on Linux, in Apple's `container` with the Swift image CI builds with (glibc, the swift.org clang with its
# sanitizers): arm64 natively, and x86-64 (an SSE2 baseline, with AVX2 as the VM reports it) translated by Rosetta. Runs
# kernels-check.sh, pair-set-check.sh, checksum-kernels-check.sh and argon2/check.sh in each, and a short fuzz when SECONDS is given.
#
#   Scripts/linux-kernels-check.sh [ARCH...]        ARCH: arm64, amd64 (default both)
#   FUZZ_SECONDS=30 Scripts/linux-kernels-check.sh   also fuzz every target that long
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
image=${LINUX_IMAGE:-swift:6.4.1-noble}
command -v container >/dev/null || { echo "[FAIL] Apple's container is not installed"; exit 2; }
container system status >/dev/null 2>&1 || container system start --enable-kernel-install
status=0
[ $# -gt 0 ] || set -- arm64 amd64
for arch in "$@"; do
    echo "== Linux $arch ($image)"
    # shellcheck disable=SC2016 # expanded in the container
    container run --rm --arch "$arch" -v "$root:/src" -e FUZZ_SECONDS="${FUZZ_SECONDS:-}" "$image" bash -c '
        set -euo pipefail
        cd /src
        bash Scripts/kernels-check.sh 2>&1 | grep -E "failures|threads|mismatches|SKIP|FAIL|rror" | grep -v " 0 mismatches" || true
        bash Scripts/kernels-check.sh > /dev/null 2>&1
        CC=clang bash Scripts/pair-set-check.sh | tail -1
        CC=clang bash Scripts/checksum-kernels-check.sh | tail -1
        CC=clang sh Scripts/argon2/check.sh | grep -E "checks|failures" | tail -3
        if [ -n "$FUZZ_SECONDS" ]; then FUZZ_CLANG=clang bash Scripts/kernels-fuzz.sh "$FUZZ_SECONDS"; fi
    ' || status=1
done
exit $status
