# shellcheck shell=sh
# shellcheck disable=SC2034 # every variable here is for the scripts that source this file
# Sourced by the C checks and benchmarks (sh, not run): where aemi's C targets keep their sources and headers, and the
# strict flags SwiftPM compiles them with, read from Package.swift, so a moved file or a new target is fixed here once.
# The caller sets AEMI_ROOT to the repository root first.
#
#   C_STRICT          strictCSettings from Package.swift
#   C_INCLUDES        -I for every C target's public headers
#   CPU_SOURCES       what any kernel needs to dispatch: CAemiCPU's feature set
#   CPU_TIMING        CAemiCPU's data-independent timing scope (only kernels handling secrets)
#   KERNELS_SOURCES   all of CAemiKernels
#   ARGON2_SOURCES    all of CAemiArgon2
#   kernels FILE...   CAemiKernels' FILE.c paths, for a check that covers some of its kernels

: "${AEMI_ROOT:?set AEMI_ROOT before sourcing Scripts/lib/c-targets.sh}"

C_STRICT=$(sed -n '/^let strictCSettings/,/^]/p' "$AEMI_ROOT/Package.swift" | grep -o '"-[^"]*"' | tr -d '"' | tr '\n' ' ')
C_INCLUDES=""
for target in CAemiCPU CAemiKernels CAemiArgon2; do
    C_INCLUDES="$C_INCLUDES -I$AEMI_ROOT/Sources/$target/include"
done
CPU_SOURCES="$AEMI_ROOT/Sources/CAemiCPU/adf_cpu_features.c"
CPU_TIMING="$AEMI_ROOT/Sources/CAemiCPU/adf_cpu_timing.c"
KERNELS_SOURCES=""
for source in "$AEMI_ROOT"/Sources/CAemiKernels/*.c; do KERNELS_SOURCES="$KERNELS_SOURCES $source"; done
ARGON2_SOURCES=""
for source in "$AEMI_ROOT"/Sources/CAemiArgon2/*.c; do ARGON2_SOURCES="$ARGON2_SOURCES $source"; done

kernels() {
    for name in "$@"; do printf '%s ' "$AEMI_ROOT/Sources/CAemiKernels/$name.c"; done
}

[ -n "$C_STRICT" ] || { echo "Scripts/lib/c-targets.sh: no strictCSettings found in Package.swift" >&2; exit 2; }
