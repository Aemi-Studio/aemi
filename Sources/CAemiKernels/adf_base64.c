//
//  adf_base64.c
//  CAemiKernels
//
//  Base64 block kernels: NEON on arm64 (a `tbl` lookup, any alphabet), SSSE3 and AVX2 on x86-64 (computed symbols, for alphabets
//  of the shape A-Za-z0-9 + two symbols), a scalar reference everywhere (ADR 0025). They convert only whole blocks; the Swift codec keeps the tails, the padding, the line
//  wrapping, the error offsets and every policy, so these kernels cannot change what is accepted or rejected.
//
//  Encode: `ld3` reads 16 groups already split into their a/b/c bytes, four shifts make the sextets, `tbl` with the
//  64-byte alphabet in four registers turns them into symbols (any alphabet, no arithmetic ranges), `st4` writes them
//  interleaved. Decode: `ld4` splits 16 groups into their four symbol lanes, `tbl` + `tbx` over the first 128 bytes of the
//  reverse table translate them, `sli` packs three bytes, `st3` writes them. No lookup indexes memory with a symbol, so the
//  kernels take the same time whatever the data (the Swift table loop does not).
//
//  Memory safety: each load and store is stated against the input and output ranges at the loop that issues it.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

/// A block kernel chosen once for a run of lines, so a line pays no dispatch (on x86-64 every dispatch asks `pthread_once`).
typedef size_t (*b64_block_decoder)(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out);
typedef size_t (*b64_block_encoder)(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out);
static b64_block_decoder b64_decoder_for(uint16_t tail);
static b64_block_encoder b64_encoder_for(uint16_t tail);

size_t adf_b64_encode_blocks_scalar(const uint8_t *table, const uint8_t *in, size_t len, uint8_t *out) {
    size_t i = 0;
    for (; i + 3 <= len; i += 3) {
        const uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i + 1] << 8) | in[i + 2];
        uint8_t *o = out + i / 3 * 4;
        o[0] = table[v >> 18];
        o[1] = table[(v >> 12) & 0x3F];
        o[2] = table[(v >> 6) & 0x3F];
        o[3] = table[v & 0x3F];
    }
    return i;
}

size_t adf_b64_decode_blocks_scalar(const uint8_t *lut, const uint8_t *in, size_t len, uint8_t *out) {
    size_t i = 0;
    for (; i + 4 <= len; i += 4) {
        const uint8_t a = lut[in[i]], b = lut[in[i + 1]], c = lut[in[i + 2]], d = lut[in[i + 3]];
        if (((a | b | c | d) & 0xC0) != 0) break;
        uint8_t *o = out + i / 4 * 3;
        o[0] = (uint8_t)((a << 2) | (b >> 4));
        o[1] = (uint8_t)((b << 4) | (c >> 2));
        o[2] = (uint8_t)((c << 6) | d);
    }
    return i;
}

#if !defined(__x86_64__)
// The x86-64 backends by name, for tests: here they are the scalar reference.
size_t adf_b64_encode_blocks_avx2(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_encode_blocks_scalar(table, in, len, out);
}
size_t adf_b64_encode_blocks_ssse3(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_encode_blocks_scalar(table, in, len, out);
}
size_t adf_b64_decode_blocks_avx2(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_decode_blocks_scalar(lut, in, len, out);
}
size_t adf_b64_decode_blocks_ssse3(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_decode_blocks_scalar(lut, in, len, out);
}
#endif

#if defined(__aarch64__)

#define ADF_B64_INLINE __attribute__((always_inline)) static inline

/// Symbols of 16 groups: `v` holds the a, b, c bytes of each group.
ADF_B64_INLINE uint8x16x4_t b64_encode16(uint8x16x4_t table, uint8x16x3_t v) {
    const uint8x16_t m = vdupq_n_u8(0x3F);
    uint8x16x4_t s;
    s.val[0] = vshrq_n_u8(v.val[0], 2);
    s.val[1] = vsriq_n_u8(vshlq_n_u8(v.val[0], 4), v.val[1], 4);  // (a << 4) | (b >> 4), then masked
    s.val[1] = vandq_u8(s.val[1], m);
    s.val[2] = vandq_u8(vsriq_n_u8(vshlq_n_u8(v.val[1], 2), v.val[2], 6), m);
    s.val[3] = vandq_u8(v.val[2], m);
    uint8x16x4_t r;
    r.val[0] = vqtbl4q_u8(table, s.val[0]);
    r.val[1] = vqtbl4q_u8(table, s.val[1]);
    r.val[2] = vqtbl4q_u8(table, s.val[2]);
    r.val[3] = vqtbl4q_u8(table, s.val[3]);
    return r;
}

size_t adf_b64_encode_blocks(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    const size_t whole = len / 3 * 3;
    if (whole < 48) return adf_b64_encode_blocks_scalar(table, in, len, out);
    const uint8x16x4_t t = vld1q_u8_x4(table);
    size_t i = 0;
    // Reads in[i ..< i + 96] (i + 96 <= whole); writes out[i / 3 * 4 ..< + 128], which is 4/3 of the bytes read.
    for (; i + 96 <= whole; i += 96) {
        const uint8x16x3_t x = vld3q_u8(in + i);
        const uint8x16x3_t y = vld3q_u8(in + i + 48);
        const uint8x16x4_t rx = b64_encode16(t, x);
        const uint8x16x4_t ry = b64_encode16(t, y);
        vst4q_u8(out + i / 3 * 4, rx);
        vst4q_u8(out + i / 3 * 4 + 64, ry);
    }
    for (; i + 48 <= whole; i += 48) {
        vst4q_u8(out + i / 3 * 4, b64_encode16(t, vld3q_u8(in + i)));
    }
    // The last 3 to 45 bytes: one more block that ends on the last whole group, re-encoding bytes already encoded into the same
    // symbols. Reads in[whole - 48 ..< whole], writes out[(whole - 48) / 3 * 4 ..< whole / 3 * 4].
    if (i < whole) vst4q_u8(out + (whole - 48) / 3 * 4, b64_encode16(t, vld3q_u8(in + whole - 48)));
    return whole;
}

/// Sextets of 16 symbols; a symbol outside the alphabet gives 0xFF (from the table) or, for a byte over 127, is caught by the caller.
ADF_B64_INLINE uint8x16_t b64_translate(uint8x16x4_t lo, uint8x16x4_t hi, uint8x16_t x) {
    const uint8x16_t r = vqtbl4q_u8(lo, x);
    return vqtbx4q_u8(r, hi, vsubq_u8(x, vdupq_n_u8(64)));
}

/// Decodes 16 groups at `in` into 48 bytes at `out`, and returns nonzero when a symbol is outside the alphabet (then `*o` is not to be stored).
ADF_B64_INLINE uint8_t b64_decode16(uint8x16x4_t lo, uint8x16x4_t hi, const uint8_t *in, uint8x16x3_t *o) {
    const uint8x16x4_t x = vld4q_u8(in);
    const uint8x16_t a = b64_translate(lo, hi, x.val[0]);
    const uint8x16_t b = b64_translate(lo, hi, x.val[1]);
    const uint8x16_t c = b64_translate(lo, hi, x.val[2]);
    const uint8x16_t d = b64_translate(lo, hi, x.val[3]);
    const uint8x16_t raw = vorrq_u8(vorrq_u8(x.val[0], x.val[1]), vorrq_u8(x.val[2], x.val[3]));
    const uint8x16_t bad = vorrq_u8(vorrq_u8(vorrq_u8(a, b), vorrq_u8(c, d)), vandq_u8(raw, vdupq_n_u8(0x80)));
    o->val[0] = vsliq_n_u8(vshrq_n_u8(b, 4), a, 2);
    o->val[1] = vsliq_n_u8(vshrq_n_u8(c, 2), b, 4);
    o->val[2] = vsliq_n_u8(d, c, 6);
    return vmaxvq_u8(vqsubq_u8(bad, vdupq_n_u8(0x3F)));
}

/// Decodes the 16 contiguous symbols at `in` into 12 bytes in the low lanes of `*o`, and returns nonzero when one is outside the
/// alphabet. For the steps that are not a whole 64-symbol block: the line tails of `.mime` (76 = 64 + 12) and `.pem` input.
ADF_B64_INLINE uint8_t b64_decode_contiguous16(uint8x16x4_t lo, uint8x16x4_t hi, const uint8_t *in, uint8x16_t *o) {
    const uint8x16_t x = vld1q_u8(in);
    const uint8x16_t s = b64_translate(lo, hi, x);
    const uint8x16_t bad = vorrq_u8(s, vandq_u8(x, vdupq_n_u8(0x80)));
    // Each u16 holds sextets (a, b) as a | b << 8: make a << 6 | b. Each u32 then holds (ab, cd): make ab << 12 | cd, a 24-bit
    // group whose bytes, high first, are the decoded bytes.
    const uint16x8_t pairs = vreinterpretq_u16_u8(s);
    const uint16x8_t ab = vorrq_u16(vshlq_n_u16(vandq_u16(pairs, vdupq_n_u16(0xFF)), 6), vshrq_n_u16(pairs, 8));
    const uint32x4_t quads = vreinterpretq_u32_u16(ab);
    const uint32x4_t group = vorrq_u32(vshlq_n_u32(vandq_u32(quads, vdupq_n_u32(0xFFFF)), 12), vshrq_n_u32(quads, 16));
    static const uint8_t order[16] = {2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 255, 255, 255, 255};
    *o = vqtbl1q_u8(vreinterpretq_u8_u32(group), vld1q_u8(order));
    return vmaxvq_u8(vqsubq_u8(bad, vdupq_n_u8(0x3F)));
}

/// Stores the 12 decoded bytes of `v` at `out` (8 + 4; nothing past `out + 12`).
ADF_B64_INLINE void b64_store12(uint8_t *out, uint8x16_t v) {
    vst1_u8(out, vget_low_u8(v));
    vst1_lane_u32((uint32_t *)(void *)(out + 8), vreinterpret_u32_u8(vget_high_u8(v)), 0);
}

size_t adf_b64_decode_blocks(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    const uint8x16x4_t lo = vld1q_u8_x4(lut);       // lut[0 ..< 64]
    const uint8x16x4_t hi = vld1q_u8_x4(lut + 64);  // lut[64 ..< 128]; bytes >= 128 are caught by the 0x80 test
    const size_t whole = len / 4 * 4;               // only whole groups are decoded
    size_t i = 0;
    // Each block reads in[i ..< i + 64] and writes out[i / 4 * 3 ..< + 48], 3/4 of the symbols read: both inside the
    // caller's ranges. A block with a bad symbol is not stored; the scalar reference then decodes from it up to the bad group,
    // so the answer is always exactly the reference's.
    uint8x16x3_t p;
    for (; i + 64 <= whole; i += 64) {
        if (b64_decode16(lo, hi, in + i, &p) != 0) goto rest;
        vst3q_u8(out + i / 4 * 3, p);
    }
    // Then 16 symbols at a time: reads in[i ..< i + 16], writes out[i / 4 * 3 ..< + 12].
    uint8x16_t q;
    for (; i + 16 <= whole; i += 16) {
        if (b64_decode_contiguous16(lo, hi, in + i, &q) != 0) goto rest;
        b64_store12(out + i / 4 * 3, q);
    }
    // The last 4, 8 or 12 symbols: one more step that ends on the last whole group, overlapping symbols already decoded
    // (and valid), which it rewrites with the same bytes. Reads in[whole - 16 ..< whole], writes out[.. ..< whole / 4 * 3].
    if (i < whole && whole >= 16) {
        const size_t start = whole - 16;
        if (b64_decode_contiguous16(lo, hi, in + start, &q) != 0) goto rest;
        b64_store12(out + start / 4 * 3, q);
        return whole;
    }
rest:
    return i + adf_b64_decode_blocks_scalar(lut, in + i, whole - i, out + i / 4 * 3);
}

static b64_block_decoder b64_decoder_for(uint16_t tail) {
    (void)tail;
    return adf_b64_decode_blocks;
}
static b64_block_encoder b64_encoder_for(uint16_t tail) {
    (void)tail;
    return adf_b64_encode_blocks;
}

#elif defined(__x86_64__)

#include <CAemiCPU.h>
#include <immintrin.h>

// x86-64 has no 64-byte table lookup, so these kernels compute the symbols: they serve an alphabet that is A-Z a-z 0-9
// followed by two symbols `plus` (sextet 62) and `slash` (63) -- standard, URL-safe, and any other alphabet of that shape.
// `tail` is `plus | slash << 8`, or 0 for any other alphabet, which these kernels leave to the caller (they return 0).

#define ADF_B64_SSSE3 __attribute__((target("ssse3")))
#define ADF_B64_AVX2 __attribute__((target("avx2")))

// Out-of-line SSSE3 entry points (defined below): a function compiled without SSSE3 may call these, never the always-inline
// steps, which on an x86-64 baseline without SSSE3 (Linux; macOS's baseline has it) cannot be inlined into it.
ADF_B64_SSSE3 static size_t b64_decode_x86_ssse3_all(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out);
ADF_B64_SSSE3 static size_t b64_encode_x86_ssse3_all(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out);

/// Offsets that turn a sextet into its symbol, picked by `subs(s, 51)` (or 13 for s < 26): Muła and Lemire's reduction.
ADF_B64_SSSE3 __attribute__((always_inline)) static inline __m128i b64_offsets(uint16_t tail) {
    const char plus = (char)(uint8_t)((tail & 0xFF) - 62), slash = (char)(uint8_t)((tail >> 8) - 63);
    return _mm_setr_epi8(71, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, plus, slash, 65, 0, 0);
}

ADF_B64_SSSE3 __attribute__((always_inline)) static inline __m128i b64_enc_sextets128(__m128i in) {
    const __m128i shuffled = _mm_shuffle_epi8(in, _mm_setr_epi8(1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10));
    const __m128i t1 = _mm_mulhi_epu16(_mm_and_si128(shuffled, _mm_set1_epi32(0x0fc0fc00)), _mm_set1_epi32(0x04000040));
    const __m128i t3 = _mm_mullo_epi16(_mm_and_si128(shuffled, _mm_set1_epi32(0x003f03f0)), _mm_set1_epi32(0x01000010));
    return _mm_or_si128(t1, t3);
}

ADF_B64_SSSE3 __attribute__((always_inline)) static inline __m128i b64_enc_symbols128(__m128i s, __m128i offsets) {
    __m128i idx = _mm_subs_epu8(s, _mm_set1_epi8(51));
    idx = _mm_or_si128(idx, _mm_and_si128(_mm_cmpgt_epi8(_mm_set1_epi8(26), s), _mm_set1_epi8(13)));
    return _mm_add_epi8(s, _mm_shuffle_epi8(offsets, idx));
}

/// Stores the low 12 bytes of `v` at `out` (8 + 4; nothing past `out + 12`).
ADF_B64_SSSE3 __attribute__((always_inline)) static inline void b64_store12_x86(uint8_t *out, __m128i v) {
    _mm_storel_epi64((__m128i *)(void *)out, v);
    const uint32_t high = (uint32_t)_mm_cvtsi128_si32(_mm_srli_si128(v, 8));
    __builtin_memcpy(out + 8, &high, 4);
}

/// Every whole group of `in[0 ..< len]`, with AVX2 when `avx2`, then SSSE3, then one overlapping step. Returns `len / 3 * 3`.
ADF_B64_SSSE3 __attribute__((always_inline)) static inline size_t b64_encode_x86_ssse3(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out,
                                                 size_t i) {
    const size_t whole = len / 3 * 3;
    if (whole < 16) return i + adf_b64_encode_blocks_scalar(table, in + i, whole - i, out + i / 3 * 4);
    const __m128i offsets = b64_offsets(tail);
    // Each step loads in[i ..< i + 16] (i + 16 <= len), uses 12 bytes, and stores 16 symbols at out[i / 3 * 4 ..< + 16].
    for (; i + 16 <= len && i + 12 <= whole; i += 12) {
        const __m128i s = b64_enc_sextets128(_mm_loadu_si128((const __m128i *)(const void *)(in + i)));
        _mm_storeu_si128((__m128i *)(void *)(out + i / 3 * 4), b64_enc_symbols128(s, offsets));
    }
    // The rest (3 to 15 bytes): 12-byte steps whose 16-byte load ends where the 12 bytes do (in[p - 4 ..< p + 12], p >= 4 since
    // the loop above ran), the last one placed to end on the last whole group; bytes encoded twice get the same symbols.
    // Writes out[p / 3 * 4 ..< (p + 12) / 3 * 4], inside out[0 ..< whole / 3 * 4].
    while (i < whole) {
        const size_t p = whole - i >= 12 ? i : whole - 12;
        const __m128i v = _mm_loadu_si128((const __m128i *)(const void *)(in + p - 4));
        const __m128i s = b64_enc_sextets128(_mm_srli_si128(v, 4));
        _mm_storeu_si128((__m128i *)(void *)(out + p / 3 * 4), b64_enc_symbols128(s, offsets));
        i = p + 12;
    }
    return whole;
}

ADF_B64_AVX2 __attribute__((always_inline)) static inline size_t b64_encode_avx2_core(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    const __m256i offsets = _mm256_broadcastsi128_si256(b64_offsets(tail));
    const __m256i shuf = _mm256_setr_epi8(1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10, 1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10);
    size_t i = 0;
    // Each step loads in[i ..< i + 16] and in[i + 12 ..< i + 28] (i + 28 <= len), uses 24 bytes, stores 32 symbols.
    for (; i + 28 <= len; i += 24) {
        const __m256i v = _mm256_inserti128_si256(
            _mm256_castsi128_si256(_mm_loadu_si128((const __m128i *)(const void *)(in + i))),
            _mm_loadu_si128((const __m128i *)(const void *)(in + i + 12)), 1);
        const __m256i shuffled = _mm256_shuffle_epi8(v, shuf);
        const __m256i t1 = _mm256_mulhi_epu16(_mm256_and_si256(shuffled, _mm256_set1_epi32(0x0fc0fc00)), _mm256_set1_epi32(0x04000040));
        const __m256i t3 = _mm256_mullo_epi16(_mm256_and_si256(shuffled, _mm256_set1_epi32(0x003f03f0)), _mm256_set1_epi32(0x01000010));
        const __m256i s = _mm256_or_si256(t1, t3);
        __m256i idx = _mm256_subs_epu8(s, _mm256_set1_epi8(51));
        idx = _mm256_or_si256(idx, _mm256_and_si256(_mm256_cmpgt_epi8(_mm256_set1_epi8(26), s), _mm256_set1_epi8(13)));
        _mm256_storeu_si256((__m256i *)(void *)(out + i / 3 * 4), _mm256_add_epi8(s, _mm256_shuffle_epi8(offsets, idx)));
    }
    return b64_encode_x86_ssse3(table, tail, in, len, out, i);  // AVX2 implies SSSE3
}

ADF_B64_AVX2 static size_t b64_encode_x86_avx2(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    return b64_encode_avx2_core(table, tail, in, len, out);
}

// The named x86-64 backends self-guard like the other kernels': without the feature, or for an alphabet of another shape
// (`tail` 0), they run the scalar reference, so any of them may be called on any host. Every one returns `len / 3 * 3`.
size_t adf_b64_encode_blocks_avx2(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || !adf_cpu_has(ADF_CPU_AVX2)) return adf_b64_encode_blocks_scalar(table, in, len, out);
    return b64_encode_x86_avx2(table, tail, in, len, out);
}

size_t adf_b64_encode_blocks_ssse3(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || !adf_cpu_has(ADF_CPU_SSSE3)) return adf_b64_encode_blocks_scalar(table, in, len, out);
    return b64_encode_x86_ssse3_all(table, tail, in, len, out);
}

size_t adf_b64_encode_blocks(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    // Rosetta 2 runs AVX2 (when it advertises it) slower than SSSE3 (measured: ADR 0025), so a translated process takes SSSE3.
    if (!adf_cpu_has(ADF_CPU_TRANSLATED)) return adf_b64_encode_blocks_avx2(table, tail, in, len, out);
    return adf_b64_encode_blocks_ssse3(table, tail, in, len, out);
}

/// The sextet of each byte of `x` and 0xFF in `*valid` lanes where it is a symbol: ranges by unsigned compare.
#define B64_DEC_BODY(VEC, SET1_EPI8, SUB, ADD, MIN, CMPEQ, AND, OR)                                     \
    const VEC u = SUB(x, SET1_EPI8('A'));                                                               \
    const VEC l = SUB(x, SET1_EPI8('a'));                                                               \
    const VEC g = SUB(x, SET1_EPI8('0'));                                                               \
    const VEC mu = CMPEQ(MIN(u, SET1_EPI8(25)), u);                                                     \
    const VEC ml = CMPEQ(MIN(l, SET1_EPI8(25)), l);                                                     \
    const VEC mg = CMPEQ(MIN(g, SET1_EPI8(9)), g);                                                      \
    const VEC mp = CMPEQ(x, plus);                                                                      \
    const VEC ms = CMPEQ(x, slash);                                                                     \
    VEC r = AND(u, mu);                                                                                 \
    r = OR(r, AND(ADD(l, SET1_EPI8(26)), ml));                                                          \
    r = OR(r, AND(ADD(g, SET1_EPI8(52)), mg));                                                          \
    r = OR(r, AND(mp, SET1_EPI8(62)));                                                                  \
    r = OR(r, AND(ms, SET1_EPI8(63)));                                                                  \
    *valid = OR(OR(OR(mu, ml), OR(mg, mp)), ms);                                                        \
    return r;

ADF_B64_SSSE3 __attribute__((always_inline)) static inline __m128i b64_dec_sextets128(__m128i x, __m128i plus, __m128i slash, __m128i *valid) {
    B64_DEC_BODY(__m128i, _mm_set1_epi8, _mm_sub_epi8, _mm_add_epi8, _mm_min_epu8, _mm_cmpeq_epi8, _mm_and_si128, _mm_or_si128)
}

ADF_B64_AVX2 static inline __m256i b64_dec_sextets256(__m256i x, __m256i plus, __m256i slash, __m256i *valid) {
    B64_DEC_BODY(__m256i, _mm256_set1_epi8, _mm256_sub_epi8, _mm256_add_epi8, _mm256_min_epu8, _mm256_cmpeq_epi8, _mm256_and_si256, _mm256_or_si256)
}

/// Every whole group up to the first holding a byte outside the alphabet, from symbol `i` on: SSSE3 16 at a time, one step that
/// overlaps to end on the last whole group, and the scalar reference from the first block with a bad byte. Exactly the reference's answer.
ADF_B64_SSSE3 __attribute__((always_inline)) static inline size_t b64_decode_x86_ssse3(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out,
                                                 size_t i) {
    const size_t whole = len / 4 * 4;
    const __m128i plus = _mm_set1_epi8((char)(tail & 0xFF)), slash = _mm_set1_epi8((char)(tail >> 8));
    const __m128i pack = _mm_setr_epi8(2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
    __m128i valid;
    // Each step loads in[i ..< i + 16] and stores 12 bytes at out[i / 4 * 3 ...]: both inside the caller's ranges.
    for (; i + 16 <= whole; i += 16) {
        const __m128i s = b64_dec_sextets128(_mm_loadu_si128((const __m128i *)(const void *)(in + i)), plus, slash, &valid);
        if (_mm_movemask_epi8(valid) != 0xFFFF) goto rest;
        const __m128i m = _mm_maddubs_epi16(s, _mm_set1_epi32(0x01400140));
        b64_store12_x86(out + i / 4 * 3, _mm_shuffle_epi8(_mm_madd_epi16(m, _mm_set1_epi32(0x00011000)), pack));
    }
    if (i < whole && whole >= 16) {
        // in[whole - 16 ..< whole]; the symbols before i were valid and decode to the same bytes again.
        const size_t start = whole - 16;
        const __m128i s = b64_dec_sextets128(_mm_loadu_si128((const __m128i *)(const void *)(in + start)), plus, slash, &valid);
        if (_mm_movemask_epi8(valid) != 0xFFFF) goto rest;
        const __m128i m = _mm_maddubs_epi16(s, _mm_set1_epi32(0x01400140));
        b64_store12_x86(out + start / 4 * 3, _mm_shuffle_epi8(_mm_madd_epi16(m, _mm_set1_epi32(0x00011000)), pack));
        return whole;
    }
rest:
    return i + adf_b64_decode_blocks_scalar(lut, in + i, whole - i, out + i / 4 * 3);
}

ADF_B64_AVX2 __attribute__((always_inline)) static inline size_t b64_decode_avx2_core(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    const size_t whole = len / 4 * 4;
    const __m256i plus = _mm256_set1_epi8((char)(tail & 0xFF)), slash = _mm256_set1_epi8((char)(tail >> 8));
    const __m256i pack = _mm256_setr_epi8(2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1, 2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
    const __m256i gather = _mm256_setr_epi32(0, 1, 2, 4, 5, 6, 7, 7);
    size_t i = 0;
    // Each step loads in[i ..< i + 32] and writes 24 bytes at out[i / 4 * 3 ...]: a 16-byte and an 8-byte store.
    for (; i + 32 <= whole; i += 32) {
        __m256i valid;
        const __m256i s = b64_dec_sextets256(_mm256_loadu_si256((const __m256i *)(const void *)(in + i)), plus, slash, &valid);
        if (_mm256_movemask_epi8(valid) != -1) break;  // the SSSE3 steps and then the reference take it from here
        const __m256i m = _mm256_maddubs_epi16(s, _mm256_set1_epi32(0x01400140));
        const __m256i d = _mm256_permutevar8x32_epi32(_mm256_shuffle_epi8(_mm256_madd_epi16(m, _mm256_set1_epi32(0x00011000)), pack), gather);
        _mm_storeu_si128((__m128i *)(void *)(out + i / 4 * 3), _mm256_castsi256_si128(d));
        _mm_storel_epi64((__m128i *)(void *)(out + i / 4 * 3 + 16), _mm256_extracti128_si256(d, 1));
    }
    return b64_decode_x86_ssse3(lut, tail, in, len, out, i);  // AVX2 implies SSSE3
}

ADF_B64_AVX2 static size_t b64_decode_x86_avx2(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    return b64_decode_avx2_core(lut, tail, in, len, out);
}

size_t adf_b64_decode_blocks_avx2(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || !adf_cpu_has(ADF_CPU_AVX2)) return adf_b64_decode_blocks_scalar(lut, in, len, out);
    return b64_decode_x86_avx2(lut, tail, in, len, out);
}

size_t adf_b64_decode_blocks_ssse3(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || !adf_cpu_has(ADF_CPU_SSSE3)) return adf_b64_decode_blocks_scalar(lut, in, len, out);
    return b64_decode_x86_ssse3_all(lut, tail, in, len, out);
}

size_t adf_b64_decode_blocks(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (!adf_cpu_has(ADF_CPU_TRANSLATED)) return adf_b64_decode_blocks_avx2(lut, tail, in, len, out);
    return adf_b64_decode_blocks_ssse3(lut, tail, in, len, out);
}

static size_t b64_scalar_decode_any(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_decode_blocks_scalar(lut, in, len, out);
}
static size_t b64_scalar_encode_any(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_encode_blocks_scalar(table, in, len, out);
}
ADF_B64_SSSE3 static size_t b64_decode_x86_ssse3_all(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    return b64_decode_x86_ssse3(lut, tail, in, len, out, 0);
}
ADF_B64_SSSE3 static size_t b64_encode_x86_ssse3_all(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    return b64_encode_x86_ssse3(table, tail, in, len, out, 0);
}

/// The same choice as the dispatchers above, made once.
static b64_block_decoder b64_decoder_for(uint16_t tail) {
    if (tail == 0) return b64_scalar_decode_any;
    if (!adf_cpu_has(ADF_CPU_TRANSLATED) && adf_cpu_has(ADF_CPU_AVX2)) return b64_decode_x86_avx2;
    return adf_cpu_has(ADF_CPU_SSSE3) ? b64_decode_x86_ssse3_all : b64_scalar_decode_any;
}
static b64_block_encoder b64_encoder_for(uint16_t tail) {
    if (tail == 0) return b64_scalar_encode_any;
    if (!adf_cpu_has(ADF_CPU_TRANSLATED) && adf_cpu_has(ADF_CPU_AVX2)) return b64_encode_x86_avx2;
    return adf_cpu_has(ADF_CPU_SSSE3) ? b64_encode_x86_ssse3_all : b64_scalar_encode_any;
}

#else

size_t adf_b64_encode_blocks(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_encode_blocks_scalar(table, in, len, out);
}
size_t adf_b64_decode_blocks(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_decode_blocks_scalar(lut, in, len, out);
}
static b64_block_decoder b64_decoder_for(uint16_t tail) {
    (void)tail;
    return adf_b64_decode_blocks;
}
static b64_block_encoder b64_encoder_for(uint16_t tail) {
    (void)tail;
    return adf_b64_encode_blocks;
}

#endif

// MARK: - Wrapped text (.mime, .pem)

static size_t b64_scalar_blocks(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_decode_blocks_scalar(lut, in, len, out);
}

/// Whole lines of exactly `width` symbols, each ended by LF or CR LF, decoded by `decode`; stops before the first line that is
/// anything else, or whose bytes would not fit in `out_cap`. Bounds: a line is read only when `width + 1` (or + 2 for CR LF)
/// bytes remain; `decode` writes at most `width / 4 * 3` bytes, and only when that many remain in `out_cap`.
__attribute__((always_inline)) static inline size_t b64_decode_lines(b64_block_decoder decode, const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len,
                               uint8_t *out, size_t out_cap, size_t width, size_t *written) {
    size_t i = 0, w = 0;
    *written = 0;
    if (width == 0 || width % 4 != 0) return 0;
    const size_t bytes = width / 4 * 3;
    while (len - i > width && out_cap - w >= bytes) {
        const uint8_t *line = in + i;
        size_t ending;
        if (line[width] == 0x0A) {
            ending = 1;
        } else if (line[width] == 0x0D && len - i > width + 1 && line[width + 1] == 0x0A) {
            ending = 2;
        } else {
            break;
        }
        if (decode(lut, tail, line, width, out + w) != width) break;
        i += width + ending;
        w += bytes;
    }
    *written = w;
    return i;
}

#if defined(__x86_64__)
// The line loops compiled for each ISA with the block kernel inlined, so the constants are built once per call rather than once
// per line and a line costs no indirect call (ADR 0025).
ADF_B64_AVX2 static size_t b64_decode_lines_avx2(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out,
                                                 size_t out_cap, size_t width, size_t *written) {
    return b64_decode_lines(b64_decode_avx2_core, lut, tail, in, len, out, out_cap, width, written);
}
ADF_B64_SSSE3 static size_t b64_decode_lines_ssse3(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out,
                                                   size_t out_cap, size_t width, size_t *written) {
    return b64_decode_lines(b64_decode_x86_ssse3_all, lut, tail, in, len, out, out_cap, width, written);
}
#endif

size_t adf_b64_decode_lines(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out, size_t out_cap,
                            size_t width, size_t *written) {
#if defined(__x86_64__)
    if (tail != 0 && !adf_cpu_has(ADF_CPU_TRANSLATED) && adf_cpu_has(ADF_CPU_AVX2))
        return b64_decode_lines_avx2(lut, tail, in, len, out, out_cap, width, written);
    if (tail != 0 && adf_cpu_has(ADF_CPU_SSSE3)) return b64_decode_lines_ssse3(lut, tail, in, len, out, out_cap, width, written);
#endif
    return b64_decode_lines(b64_decoder_for(tail), lut, tail, in, len, out, out_cap, width, written);
}

size_t adf_b64_decode_lines_scalar(const uint8_t *lut, const uint8_t *in, size_t len, uint8_t *out, size_t out_cap,
                                   size_t width, size_t *written) {
    return b64_decode_lines(b64_scalar_blocks, lut, 0, in, len, out, out_cap, width, written);
}

static size_t b64_scalar_encode(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    return adf_b64_encode_blocks_scalar(table, in, len, out);
}

/// Whole lines of `width` symbols (`width / 4 * 3` input bytes), each followed by LF or CR LF, while more input follows the line
/// (so the ending is between lines, never after the last) and the line and its ending fit in `out_cap`.
__attribute__((always_inline)) static inline size_t b64_encode_lines(b64_block_encoder encode, const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len,
                               uint8_t *out, size_t out_cap, size_t width, int crlf, size_t *written) {
    size_t i = 0, w = 0;
    *written = 0;
    if (width == 0 || width % 4 != 0) return 0;
    const size_t bytes = width / 4 * 3, ending = crlf ? 2 : 1;
    while (len - i > bytes && out_cap - w >= width + ending) {
        // Reads in[i ..< i + bytes]; writes out[w ..< w + width + ending].
        encode(table, tail, in + i, bytes, out + w);
        w += width;
        if (crlf) out[w++] = 0x0D;
        out[w++] = 0x0A;
        i += bytes;
    }
    *written = w;
    return i;
}

#if defined(__x86_64__)
ADF_B64_AVX2 static size_t b64_encode_lines_avx2(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out,
                                                 size_t out_cap, size_t width, int crlf, size_t *written) {
    return b64_encode_lines(b64_encode_avx2_core, table, tail, in, len, out, out_cap, width, crlf, written);
}
ADF_B64_SSSE3 static size_t b64_encode_lines_ssse3(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out,
                                                   size_t out_cap, size_t width, int crlf, size_t *written) {
    return b64_encode_lines(b64_encode_x86_ssse3_all, table, tail, in, len, out, out_cap, width, crlf, written);
}
#endif

size_t adf_b64_encode_lines(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out, size_t out_cap,
                            size_t width, int crlf, size_t *written) {
#if defined(__x86_64__)
    if (tail != 0 && !adf_cpu_has(ADF_CPU_TRANSLATED) && adf_cpu_has(ADF_CPU_AVX2))
        return b64_encode_lines_avx2(table, tail, in, len, out, out_cap, width, crlf, written);
    if (tail != 0 && adf_cpu_has(ADF_CPU_SSSE3)) return b64_encode_lines_ssse3(table, tail, in, len, out, out_cap, width, crlf, written);
#endif
    return b64_encode_lines(b64_encoder_for(tail), table, tail, in, len, out, out_cap, width, crlf, written);
}

size_t adf_b64_encode_lines_scalar(const uint8_t *table, const uint8_t *in, size_t len, uint8_t *out, size_t out_cap, size_t width,
                                   int crlf, size_t *written) {
    return b64_encode_lines(b64_scalar_encode, table, 0, in, len, out, out_cap, width, crlf, written);
}
