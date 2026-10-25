//
//  adf_neon_scan.h
//  CAemiKernels
//
//  One scanning skeleton for every arm64 "first byte that matches a predicate" kernel, so that the
//  five of them (any5, control_or_any5, nonascii, string_stop, first_disallowed_text) cannot differ in
//  how they handle the end of the input or locate a hit.
//
//  What it does, against the loop each kernel had before (a 16-byte step, a scalar rescan of the 16
//  bytes holding a hit, a scalar loop for the last 0-15 bytes):
//  - A hit is located from the compare mask: `vshrn` narrows 16 byte lanes to 4 bits each in one
//    64-bit word, and `ctz` divides by 4 (NEON has no movemask). No rescan.
//  - The tail is one more vector load that ends at the last byte. It overlaps bytes already scanned,
//    which held no hit (or the scan would have returned), so the first set lane is always a new byte.
//  - An input of 8 to 15 bytes is two overlapping 8-byte loads combined into one vector.
//  - Only an input of fewer than 8 bytes takes the scalar path.
//  - 64 bytes are tested per iteration with one reduction.
//
//  Memory safety: every load lies inside [buf, buf + len). The invariant is stated at each load.
//

#ifndef ADF_NEON_SCAN_H
#define ADF_NEON_SCAN_H

#if defined(__aarch64__)

#include <arm_neon.h>
#include <stddef.h>
#include <stdint.h>

/// Returns 0xFF in each lane of `v` that ends the scan, 0 elsewhere.
typedef uint8x16_t (*adf_classify16)(uint8x16_t v, const void *ctx);

/// The scalar reference over `buf[0..<len]`: the index of the first stop byte, or `len`.
typedef size_t (*adf_scalar_scan)(const uint8_t *buf, size_t len, const void *ctx);

/// Four bits per lane, lane 0 lowest: nonzero iff some lane of `mask` is set.
__attribute__((always_inline)) static inline uint64_t adf_neon_lane_bits(uint8x16_t mask) {
    return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0);
}

/// The index of the lowest set lane. - Precondition: `bits` is nonzero.
__attribute__((always_inline)) static inline size_t adf_neon_first_lane(uint64_t bits) {
    return (size_t)(__builtin_ctzll(bits) >> 2);
}

/// The index of the first byte of `buf[0..<len]` that `classify` marks, or `len`.
///
/// - Complexity: O(first hit); about len / 64 iterations with no hit.
/// - Precondition: `buf` is readable for `len` bytes. Nothing is read outside that range.
__attribute__((always_inline)) static inline size_t adf_neon_scan(
    const uint8_t *buf, size_t len, adf_classify16 classify, adf_scalar_scan scalar, const void *ctx) {
    size_t i = 0;
    // Each load below is buf[i ..< i + 64]: inside the input because i + 64 <= len.
    for (; i + 64 <= len; i += 64) {
        const uint8x16_t m0 = classify(vld1q_u8(buf + i), ctx);
        const uint8x16_t m1 = classify(vld1q_u8(buf + i + 16), ctx);
        const uint8x16_t m2 = classify(vld1q_u8(buf + i + 32), ctx);
        const uint8x16_t m3 = classify(vld1q_u8(buf + i + 48), ctx);
        if (vmaxvq_u8(vorrq_u8(vorrq_u8(m0, m1), vorrq_u8(m2, m3))) != 0) {
            uint64_t bits = adf_neon_lane_bits(m0);
            if (bits != 0) return i + adf_neon_first_lane(bits);
            bits = adf_neon_lane_bits(m1);
            if (bits != 0) return i + 16 + adf_neon_first_lane(bits);
            bits = adf_neon_lane_bits(m2);
            if (bits != 0) return i + 32 + adf_neon_first_lane(bits);
            return i + 48 + adf_neon_first_lane(adf_neon_lane_bits(m3));
        }
    }
    for (; i + 16 <= len; i += 16) {  // buf[i ..< i + 16] is inside the input
        const uint64_t bits = adf_neon_lane_bits(classify(vld1q_u8(buf + i), ctx));
        if (bits != 0) return i + adf_neon_first_lane(bits);
    }
    if (i == len) return len;
    if (len >= 16) {
        // buf[len - 16 ..< len]. Bytes below i were scanned and held no hit, so any set lane is new.
        const uint64_t bits = adf_neon_lane_bits(classify(vld1q_u8(buf + len - 16), ctx));
        return bits != 0 ? len - 16 + adf_neon_first_lane(bits) : len;
    }
    if (len >= 8) {
        // buf[0 ..< 8] and buf[len - 8 ..< len], both inside the input because 8 <= len. Lane k < 8 is
        // byte k; lane k >= 8 is byte len - 8 + (k - 8). A byte in both halves is found in the first.
        const uint8x16_t v = vcombine_u8(vld1_u8(buf), vld1_u8(buf + len - 8));
        const uint64_t bits = adf_neon_lane_bits(classify(v, ctx));
        if (bits == 0) return len;
        const size_t lane = adf_neon_first_lane(bits);
        return lane < 8 ? lane : len - 8 + (lane - 8);
    }
    return scalar(buf, len, ctx);
}

#endif  // __aarch64__
#endif  // ADF_NEON_SCAN_H
