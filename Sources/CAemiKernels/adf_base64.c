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
    const uint8x16x4_t t = vld1q_u8_x4(table);
    size_t i = 0;
    // Reads in[i ..< i + 96] (i + 96 <= len); writes out[i / 3 * 4 ..< + 128], which is 4/3 of the bytes read.
    for (; i + 96 <= len; i += 96) {
        const uint8x16x3_t x = vld3q_u8(in + i);
        const uint8x16x3_t y = vld3q_u8(in + i + 48);
        const uint8x16x4_t rx = b64_encode16(t, x);
        const uint8x16x4_t ry = b64_encode16(t, y);
        vst4q_u8(out + i / 3 * 4, rx);
        vst4q_u8(out + i / 3 * 4 + 64, ry);
    }
    for (; i + 48 <= len; i += 48) {
        vst4q_u8(out + i / 3 * 4, b64_encode16(t, vld3q_u8(in + i)));
    }
    return i;
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

size_t adf_b64_decode_blocks(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    (void)tail;
    const uint8x16x4_t lo = vld1q_u8_x4(lut);       // lut[0 ..< 64]
    const uint8x16x4_t hi = vld1q_u8_x4(lut + 64);  // lut[64 ..< 128]; bytes >= 128 are caught by the 0x80 test
    size_t i = 0;
    // Each block reads in[i ..< i + 64] and writes out[i / 4 * 3 ..< + 48], 3/4 of the symbols read: both inside the
    // caller's ranges. A block with a bad symbol is not stored.
    uint8x16x3_t p;
    for (; i + 64 <= len; i += 64) {
        if (b64_decode16(lo, hi, in + i, &p) != 0) return i;
        vst3q_u8(out + i / 4 * 3, p);
    }
    return i;
}

#elif defined(__x86_64__)

#include <CAemiCPU.h>
#include <immintrin.h>

// x86-64 has no 64-byte table lookup, so these kernels compute the symbols: they serve an alphabet that is A-Z a-z 0-9
// followed by two symbols `plus` (sextet 62) and `slash` (63) -- standard, URL-safe, and any other alphabet of that shape.
// `tail` is `plus | slash << 8`, or 0 for any other alphabet, which these kernels leave to the caller (they return 0).

#define ADF_B64_SSSE3 __attribute__((target("ssse3")))
#define ADF_B64_AVX2 __attribute__((target("avx2")))

/// Offsets that turn a sextet into its symbol, picked by `subs(s, 51)` (or 13 for s < 26): Muła and Lemire's reduction.
static void b64_offsets(uint16_t tail, uint8_t offsets[16]) {
    const uint8_t plus = (uint8_t)(tail & 0xFF), slash = (uint8_t)(tail >> 8);
    offsets[0] = 71;
    for (int i = 1; i <= 10; i++) offsets[i] = (uint8_t)(0 - 4);
    offsets[11] = (uint8_t)(plus - 62);
    offsets[12] = (uint8_t)(slash - 63);
    offsets[13] = 65;
    offsets[14] = 0;
    offsets[15] = 0;
}

ADF_B64_SSSE3 static inline __m128i b64_enc_sextets128(__m128i in) {
    const __m128i shuffled = _mm_shuffle_epi8(in, _mm_setr_epi8(1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10));
    const __m128i t1 = _mm_mulhi_epu16(_mm_and_si128(shuffled, _mm_set1_epi32(0x0fc0fc00)), _mm_set1_epi32(0x04000040));
    const __m128i t3 = _mm_mullo_epi16(_mm_and_si128(shuffled, _mm_set1_epi32(0x003f03f0)), _mm_set1_epi32(0x01000010));
    return _mm_or_si128(t1, t3);
}

ADF_B64_SSSE3 static inline __m128i b64_enc_symbols128(__m128i s, __m128i offsets) {
    __m128i idx = _mm_subs_epu8(s, _mm_set1_epi8(51));
    idx = _mm_or_si128(idx, _mm_and_si128(_mm_cmpgt_epi8(_mm_set1_epi8(26), s), _mm_set1_epi8(13)));
    return _mm_add_epi8(s, _mm_shuffle_epi8(offsets, idx));
}

ADF_B64_SSSE3 static size_t b64_encode_ssse3(uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    uint8_t o[16];
    b64_offsets(tail, o);
    const __m128i offsets = _mm_loadu_si128((const __m128i *)(const void *)o);
    size_t i = 0;
    // Each step loads in[i ..< i + 16] (i + 16 <= len), uses 12 bytes, and stores 16 symbols at out[i / 3 * 4 ..< + 16].
    for (; i + 16 <= len; i += 12) {
        const __m128i s = b64_enc_sextets128(_mm_loadu_si128((const __m128i *)(const void *)(in + i)));
        _mm_storeu_si128((__m128i *)(void *)(out + i / 3 * 4), b64_enc_symbols128(s, offsets));
    }
    return i;
}

ADF_B64_AVX2 static size_t b64_encode_avx2(uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    uint8_t o[16];
    b64_offsets(tail, o);
    const __m256i offsets = _mm256_broadcastsi128_si256(_mm_loadu_si128((const __m128i *)(const void *)o));
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
    return i;
}

// The named x86-64 backends self-guard like the other kernels': without the feature, or for an alphabet of another shape
// (`tail` 0), they run the scalar reference, so any of them may be called on any host.
size_t adf_b64_encode_blocks_avx2(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || len < 28 || !adf_cpu_has(ADF_CPU_AVX2)) return adf_b64_encode_blocks_scalar(table, in, len, out);
    const size_t done = b64_encode_avx2(tail, in, len, out);
    if (len - done >= 16) return done + b64_encode_ssse3(tail, in + done, len - done, out + done / 3 * 4);  // AVX2 implies SSSE3
    return done;
}

size_t adf_b64_encode_blocks_ssse3(const uint8_t *table, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || len < 16 || !adf_cpu_has(ADF_CPU_SSSE3)) return adf_b64_encode_blocks_scalar(table, in, len, out);
    return b64_encode_ssse3(tail, in, len, out);
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

ADF_B64_SSSE3 static inline __m128i b64_dec_sextets128(__m128i x, __m128i plus, __m128i slash, __m128i *valid) {
    B64_DEC_BODY(__m128i, _mm_set1_epi8, _mm_sub_epi8, _mm_add_epi8, _mm_min_epu8, _mm_cmpeq_epi8, _mm_and_si128, _mm_or_si128)
}

ADF_B64_AVX2 static inline __m256i b64_dec_sextets256(__m256i x, __m256i plus, __m256i slash, __m256i *valid) {
    B64_DEC_BODY(__m256i, _mm256_set1_epi8, _mm256_sub_epi8, _mm256_add_epi8, _mm256_min_epu8, _mm256_cmpeq_epi8, _mm256_and_si256, _mm256_or_si256)
}

ADF_B64_SSSE3 static size_t b64_decode_ssse3(uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    const __m128i plus = _mm_set1_epi8((char)(tail & 0xFF)), slash = _mm_set1_epi8((char)(tail >> 8));
    const __m128i pack = _mm_setr_epi8(2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
    size_t i = 0;
    // Each step loads in[i ..< i + 16] and stores 16 bytes at out[i / 4 * 3 ...], of which 12 are decoded. The caller's room
    // is len / 4 * 3 bytes, and i / 4 * 3 + 16 <= len / 4 * 3 holds exactly when i + 24 <= len.
    for (; i + 24 <= len; i += 16) {
        __m128i valid;
        const __m128i s = b64_dec_sextets128(_mm_loadu_si128((const __m128i *)(const void *)(in + i)), plus, slash, &valid);
        if (_mm_movemask_epi8(valid) != 0xFFFF) return i;
        const __m128i m = _mm_maddubs_epi16(s, _mm_set1_epi32(0x01400140));
        const __m128i d = _mm_shuffle_epi8(_mm_madd_epi16(m, _mm_set1_epi32(0x00011000)), pack);
        _mm_storeu_si128((__m128i *)(void *)(out + i / 4 * 3), d);
    }
    return i;
}

ADF_B64_AVX2 static size_t b64_decode_avx2(uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    const __m256i plus = _mm256_set1_epi8((char)(tail & 0xFF)), slash = _mm256_set1_epi8((char)(tail >> 8));
    const __m256i pack = _mm256_setr_epi8(2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1, 2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
    const __m256i gather = _mm256_setr_epi32(0, 1, 2, 4, 5, 6, 7, 7);
    size_t i = 0;
    // Each step loads in[i ..< i + 32] and writes 24 bytes at out[i / 4 * 3 ...]: a 16-byte and an 8-byte store.
    for (; i + 32 <= len; i += 32) {
        __m256i valid;
        const __m256i s = b64_dec_sextets256(_mm256_loadu_si256((const __m256i *)(const void *)(in + i)), plus, slash, &valid);
        if (_mm256_movemask_epi8(valid) != -1) return i;
        const __m256i m = _mm256_maddubs_epi16(s, _mm256_set1_epi32(0x01400140));
        const __m256i d = _mm256_permutevar8x32_epi32(_mm256_shuffle_epi8(_mm256_madd_epi16(m, _mm256_set1_epi32(0x00011000)), pack), gather);
        _mm_storeu_si128((__m128i *)(void *)(out + i / 4 * 3), _mm256_castsi256_si128(d));
        _mm_storel_epi64((__m128i *)(void *)(out + i / 4 * 3 + 16), _mm256_extracti128_si256(d, 1));
    }
    return i;
}

size_t adf_b64_decode_blocks_avx2(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || len < 32 || !adf_cpu_has(ADF_CPU_AVX2)) return adf_b64_decode_blocks_scalar(lut, in, len, out);
    const size_t done = b64_decode_avx2(tail, in, len, out);
    return done + adf_b64_decode_blocks_scalar(lut, in + done, len - done, out + done / 4 * 3);
}

size_t adf_b64_decode_blocks_ssse3(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (tail == 0 || len < 24 || !adf_cpu_has(ADF_CPU_SSSE3)) return adf_b64_decode_blocks_scalar(lut, in, len, out);
    const size_t done = b64_decode_ssse3(tail, in, len, out);
    return done + adf_b64_decode_blocks_scalar(lut, in + done, len - done, out + done / 4 * 3);
}

size_t adf_b64_decode_blocks(const uint8_t *lut, uint16_t tail, const uint8_t *in, size_t len, uint8_t *out) {
    if (!adf_cpu_has(ADF_CPU_TRANSLATED)) return adf_b64_decode_blocks_avx2(lut, tail, in, len, out);
    return adf_b64_decode_blocks_ssse3(lut, tail, in, len, out);
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

#endif
