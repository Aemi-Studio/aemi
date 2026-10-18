// Scalar references for the C kernel benchmark, compiled once per optimization setting.
//
// `bench-c-kernels.sh` builds this file several times with a different `VARIANT` and flags, so each
// baseline is the same source under a different compiler configuration, in its own translation unit:
// the harness reaches it through a function pointer and can neither inline nor delete it.

#include <stddef.h>
#include <stdint.h>

#ifndef VARIANT
#error "compile with -DVARIANT=<suffix>"
#endif

#define CONCAT_(a, b) a##b
#define CONCAT(a, b) CONCAT_(a, b)

void CONCAT(ref_fold_ascii_, VARIANT)(uint8_t *dst, const uint8_t *src, size_t len);
size_t CONCAT(ref_index_of_nonascii_, VARIANT)(const uint8_t *buf, size_t len);

// Verbatim bodies of `adf_fold_ascii_scalar` and `adf_index_of_nonascii_scalar`.
void CONCAT(ref_fold_ascii_, VARIANT)(uint8_t *dst, const uint8_t *src, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = src[i];
        dst[i] = (b >= 0x41 && b <= 0x5A) ? (uint8_t)(b | 0x20) : b;
    }
}

size_t CONCAT(ref_index_of_nonascii_, VARIANT)(const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (buf[i] >= 0x80) {
            return i;
        }
    }
    return len;
}
