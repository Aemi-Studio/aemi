//
//  adf_utf16.c
//  CAemiKernels
//
//  The ASCII prefix of UTF-16LE text, narrowed to bytes (ADR 0020, promoted from MacFS, where NTFS names are mostly
//  ASCII). arm64: eight units per step, `umaxv` to test them and `xtn` to narrow. x86-64 (SSE2 is baseline): a mask of
//  the bits a unit below 0x80 never has, then `packus`. The first unit that is not ASCII finishes byte by byte.
//

#include "CAemiKernels.h"

#include <string.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#if defined(__x86_64__)
#include <emmintrin.h>
#endif

size_t adf_utf16le_ascii_prefix_scalar(const uint8_t *units, size_t count, uint8_t *ascii) {
    size_t i = 0;
    for (; i < count; ++i) {
        if (units[2 * i + 1] != 0 || units[2 * i] >= 0x80) {
            break;
        }
        ascii[i] = units[2 * i];
    }
    return i;
}

size_t adf_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii) {
    size_t i = 0;
#if defined(__aarch64__)
    for (; i + 8 <= count; i += 8) {
        const uint16x8_t block = vreinterpretq_u16_u8(vld1q_u8(units + 2 * i));
        if (vmaxvq_u16(block) >= 0x80) {
            break;
        }
        vst1_u8(ascii + i, vmovn_u16(block));
    }
#elif defined(__x86_64__)
    const __m128i high = _mm_set1_epi16((short)0xFF80);
    for (; i + 8 <= count; i += 8) {
        const __m128i block = _mm_loadu_si128((const __m128i *)(const void *)(units + 2 * i));
        if (_mm_movemask_epi8(_mm_cmpeq_epi16(_mm_and_si128(block, high), _mm_setzero_si128())) != 0xFFFF) {
            break;
        }
        _mm_storel_epi64((__m128i *)(void *)(ascii + i), _mm_packus_epi16(block, block));
    }
#endif
    return i + adf_utf16le_ascii_prefix_scalar(units + 2 * i, count - i, ascii + i);
}
