#!/bin/sh
# AemiKernels and AemiKernel as Embedded Swift (no runtime, no Foundation, no Unicode tables), for x86_64 and arm64
# macOS, with CAemiKernels' C and the part of CAemiCPU it calls, built from the shipped include directories only, as an
# Embedded consumer (WineKit's libwinekit.a, inside Wine's ntdll) builds them. Fails when the objects need any symbol
# outside libc and compiler-rt's CPU model: a `swift_*` or `__swift_stdlib_*` symbol means something pulled in the
# runtime or the Unicode tables. Exit 0 when both architectures are clean.
# SWIFTC: a swift.org toolchain's swiftc (Xcode's has no Embedded standard library), e.g.
#   SWIFTC=~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin/swiftc
set -eu
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
OUT="${TMPDIR:-/tmp}/aemi-embedded"
AEMI_ROOT=$(pwd)
. "$AEMI_ROOT/Scripts/lib/c-targets.sh"
# Swift sees CAemiKernels' shipped module map and nothing else, as a consumer outside SwiftPM does.
KERNELS_INCLUDE="Sources/CAemiKernels/include"
# libc, and compiler-rt's __cpu_model and __cpu_indicator_init (`__builtin_cpu_supports` on x86-64).
ALLOWED="__bzero __cpu_indicator_init __cpu_model arc4random_buf bzero free memchr memcmp memcpy memmove memset posix_memalign pthread_once strlen sysctlbyname"
SWIFT_FLAGS="-enable-experimental-feature Embedded -wmo -Osize -parse-as-library -strict-memory-safety -Xfrontend -disable-stack-protector"
status=0
for arch in arm64 x86_64; do
    target="$arch-apple-macos15"
    dir="$OUT/$arch"
    rm -rf "$dir"
    mkdir -p "$dir"
    for source in $KERNELS_SOURCES $CPU_SOURCES; do
        # shellcheck disable=SC2086
        clang -target "$target" -O2 $C_STRICT $C_INCLUDES -c "$source" -o "$dir/$(basename "$source" .c).o"
    done
    # shellcheck disable=SC2086
    "$SWIFTC" -target "$target" $SWIFT_FLAGS -I "$KERNELS_INCLUDE" -module-name AemiKernels Sources/AemiKernels/*.swift \
        -emit-module -emit-module-path "$dir/AemiKernels.swiftmodule" -emit-object -o "$dir/AemiKernels.swift.o"
    # shellcheck disable=SC2086
    "$SWIFTC" -target "$target" $SWIFT_FLAGS -I "$KERNELS_INCLUDE" -I "$dir" -module-name AemiKernel Sources/AemiKernel/*.swift \
        -emit-module -emit-module-path "$dir/AemiKernel.swiftmodule" -emit-object -o "$dir/AemiKernel.swift.o"
    nm -gU "$dir"/*.o 2>/dev/null | awk 'NF >= 3 { print $3 }' | sed 's/^_//' | sort -u > "$dir/defined"
    nm -u "$dir"/*.o 2>/dev/null | grep -v ':$' | awk 'NF { print $NF }' | sed 's/^_//' | sort -u > "$dir/undefined"
    comm -23 "$dir/undefined" "$dir/defined" > "$dir/needed"
    # shellcheck disable=SC2086 # one allowed symbol per word
    printf '%s\n' $ALLOWED | sort -u > "$dir/allowed"
    unexpected=$(comm -23 "$dir/needed" "$dir/allowed")
    echo "$arch: needs $(tr '\n' ' ' < "$dir/needed")"
    if [ -n "$unexpected" ]; then
        echo "$arch: NOT EMBEDDED-CLEAN, beyond libc: $(echo "$unexpected" | tr '\n' ' ')"
        status=1
    fi
done
[ "$status" -eq 0 ] && echo "ok: AemiKernels and AemiKernel build as Embedded Swift, needing libc only"
exit "$status"
