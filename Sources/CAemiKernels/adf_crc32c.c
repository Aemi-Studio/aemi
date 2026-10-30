//
//  adf_crc32c.c
//  CAemiKernels
//
//  CRC-32C (Castagnoli, reflected), raw update (ADR 0020, promoted from MacFS). arm64 with CRC32 and PMULL: from 4 KiB, the
//  hybrid below (vector folds and three `crc32cx` streams in one loop); from 256 bytes, eight 128-bit accumulators fold 128
//  bytes per step with PMULL (lane 0 times x^(8D+31), lane 1 times x^(8D-33) mod P, bit-reflected, D the fold distance),
//  joined with SHA3's `eor3` where the target has it, merge by 16-byte folds and reduce with two `crc32cx`; the rest with
//  `crc32cx`, `crc32cw`, `crc32ch` and `crc32cb`. Where the target guarantees CRC32 and AES (every Apple arm64 one) there is
//  no runtime check. x86-64 with SSE4.2: `crc32` eight bytes at a time. Otherwise, and as the oracle: one table lookup per
//  byte. The derivation is MacFS's docs/research/2026-10-30-neon-kernels.md.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include <arm_acle.h>
#include <arm_neon.h>
#include <string.h>
#endif
#if defined(__x86_64__)
#include <immintrin.h>
#include <string.h>
#endif

// table[n] = CRC-32C of the byte n alone (generated).
static const uint32_t table[256] = {
    0x00000000u, 0xf26b8303u, 0xe13b70f7u, 0x1350f3f4u, 0xc79a971fu, 0x35f1141cu,
    0x26a1e7e8u, 0xd4ca64ebu, 0x8ad958cfu, 0x78b2dbccu, 0x6be22838u, 0x9989ab3bu,
    0x4d43cfd0u, 0xbf284cd3u, 0xac78bf27u, 0x5e133c24u, 0x105ec76fu, 0xe235446cu,
    0xf165b798u, 0x030e349bu, 0xd7c45070u, 0x25afd373u, 0x36ff2087u, 0xc494a384u,
    0x9a879fa0u, 0x68ec1ca3u, 0x7bbcef57u, 0x89d76c54u, 0x5d1d08bfu, 0xaf768bbcu,
    0xbc267848u, 0x4e4dfb4bu, 0x20bd8edeu, 0xd2d60dddu, 0xc186fe29u, 0x33ed7d2au,
    0xe72719c1u, 0x154c9ac2u, 0x061c6936u, 0xf477ea35u, 0xaa64d611u, 0x580f5512u,
    0x4b5fa6e6u, 0xb93425e5u, 0x6dfe410eu, 0x9f95c20du, 0x8cc531f9u, 0x7eaeb2fau,
    0x30e349b1u, 0xc288cab2u, 0xd1d83946u, 0x23b3ba45u, 0xf779deaeu, 0x05125dadu,
    0x1642ae59u, 0xe4292d5au, 0xba3a117eu, 0x4851927du, 0x5b016189u, 0xa96ae28au,
    0x7da08661u, 0x8fcb0562u, 0x9c9bf696u, 0x6ef07595u, 0x417b1dbcu, 0xb3109ebfu,
    0xa0406d4bu, 0x522bee48u, 0x86e18aa3u, 0x748a09a0u, 0x67dafa54u, 0x95b17957u,
    0xcba24573u, 0x39c9c670u, 0x2a993584u, 0xd8f2b687u, 0x0c38d26cu, 0xfe53516fu,
    0xed03a29bu, 0x1f682198u, 0x5125dad3u, 0xa34e59d0u, 0xb01eaa24u, 0x42752927u,
    0x96bf4dccu, 0x64d4cecfu, 0x77843d3bu, 0x85efbe38u, 0xdbfc821cu, 0x2997011fu,
    0x3ac7f2ebu, 0xc8ac71e8u, 0x1c661503u, 0xee0d9600u, 0xfd5d65f4u, 0x0f36e6f7u,
    0x61c69362u, 0x93ad1061u, 0x80fde395u, 0x72966096u, 0xa65c047du, 0x5437877eu,
    0x4767748au, 0xb50cf789u, 0xeb1fcbadu, 0x197448aeu, 0x0a24bb5au, 0xf84f3859u,
    0x2c855cb2u, 0xdeeedfb1u, 0xcdbe2c45u, 0x3fd5af46u, 0x7198540du, 0x83f3d70eu,
    0x90a324fau, 0x62c8a7f9u, 0xb602c312u, 0x44694011u, 0x5739b3e5u, 0xa55230e6u,
    0xfb410cc2u, 0x092a8fc1u, 0x1a7a7c35u, 0xe811ff36u, 0x3cdb9bddu, 0xceb018deu,
    0xdde0eb2au, 0x2f8b6829u, 0x82f63b78u, 0x709db87bu, 0x63cd4b8fu, 0x91a6c88cu,
    0x456cac67u, 0xb7072f64u, 0xa457dc90u, 0x563c5f93u, 0x082f63b7u, 0xfa44e0b4u,
    0xe9141340u, 0x1b7f9043u, 0xcfb5f4a8u, 0x3dde77abu, 0x2e8e845fu, 0xdce5075cu,
    0x92a8fc17u, 0x60c37f14u, 0x73938ce0u, 0x81f80fe3u, 0x55326b08u, 0xa759e80bu,
    0xb4091bffu, 0x466298fcu, 0x1871a4d8u, 0xea1a27dbu, 0xf94ad42fu, 0x0b21572cu,
    0xdfeb33c7u, 0x2d80b0c4u, 0x3ed04330u, 0xccbbc033u, 0xa24bb5a6u, 0x502036a5u,
    0x4370c551u, 0xb11b4652u, 0x65d122b9u, 0x97baa1bau, 0x84ea524eu, 0x7681d14du,
    0x2892ed69u, 0xdaf96e6au, 0xc9a99d9eu, 0x3bc21e9du, 0xef087a76u, 0x1d63f975u,
    0x0e330a81u, 0xfc588982u, 0xb21572c9u, 0x407ef1cau, 0x532e023eu, 0xa145813du,
    0x758fe5d6u, 0x87e466d5u, 0x94b49521u, 0x66df1622u, 0x38cc2a06u, 0xcaa7a905u,
    0xd9f75af1u, 0x2b9cd9f2u, 0xff56bd19u, 0x0d3d3e1au, 0x1e6dcdeeu, 0xec064eedu,
    0xc38d26c4u, 0x31e6a5c7u, 0x22b65633u, 0xd0ddd530u, 0x0417b1dbu, 0xf67c32d8u,
    0xe52cc12cu, 0x1747422fu, 0x49547e0bu, 0xbb3ffd08u, 0xa86f0efcu, 0x5a048dffu,
    0x8ecee914u, 0x7ca56a17u, 0x6ff599e3u, 0x9d9e1ae0u, 0xd3d3e1abu, 0x21b862a8u,
    0x32e8915cu, 0xc083125fu, 0x144976b4u, 0xe622f5b7u, 0xf5720643u, 0x07198540u,
    0x590ab964u, 0xab613a67u, 0xb831c993u, 0x4a5a4a90u, 0x9e902e7bu, 0x6cfbad78u,
    0x7fab5e8cu, 0x8dc0dd8fu, 0xe330a81au, 0x115b2b19u, 0x020bd8edu, 0xf0605beeu,
    0x24aa3f05u, 0xd6c1bc06u, 0xc5914ff2u, 0x37faccf1u, 0x69e9f0d5u, 0x9b8273d6u,
    0x88d28022u, 0x7ab90321u, 0xae7367cau, 0x5c18e4c9u, 0x4f48173du, 0xbd23943eu,
    0xf36e6f75u, 0x0105ec76u, 0x12551f82u, 0xe03e9c81u, 0x34f4f86au, 0xc69f7b69u,
    0xd5cf889du, 0x27a40b9eu, 0x79b737bau, 0x8bdcb4b9u, 0x988c474du, 0x6ae7c44eu,
    0xbe2da0a5u, 0x4c4623a6u, 0x5f16d052u, 0xad7d5351u
};

uint32_t adf_crc32c_update_scalar(uint32_t crc, const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        crc = (crc >> 8) ^ table[(crc ^ buf[i]) & 0xFFu];
    }
    return crc;
}

#if defined(__aarch64__)
// Eight bytes per `crc32cx`, then one step each of four, two and one: a 12-byte name is two instructions, not five.
__attribute__((target("+crc"), always_inline)) static inline uint32_t crc_words(uint32_t crc, const uint8_t *buf, size_t len) {
    for (; len >= 8; buf += 8, len -= 8) {
        uint64_t word;
        memcpy(&word, buf, 8);
        crc = __crc32cd(crc, word);
    }
    if (len & 4) {
        uint32_t word;
        memcpy(&word, buf, 4);
        crc = __crc32cw(crc, word);
        buf += 4;
    }
    if (len & 2) {
        uint16_t half;
        memcpy(&half, buf, 2);
        crc = __crc32ch(crc, half);
        buf += 2;
    }
    if (len & 1) {
        crc = __crc32cb(crc, *buf);
    }
    return crc;
}

#if defined(__ARM_FEATURE_SHA3)
// With SHA3 (every Apple arm64 core), `eor3` joins the two products and the block in one instruction.
__attribute__((target("+aes+sha3"), always_inline)) static inline uint64x2_t crc_fold(
    uint64x2_t acc, uint64x2_t block, poly64_t k0, poly64_t k1) {
    const poly128_t low = vmull_p64((poly64_t)vgetq_lane_u64(acc, 0), k0);
    const poly128_t high = vmull_p64((poly64_t)vgetq_lane_u64(acc, 1), k1);
    return veor3q_u64(vreinterpretq_u64_p128(low), vreinterpretq_u64_p128(high), block);
}
#else
__attribute__((target("+aes"), always_inline)) static inline uint64x2_t crc_fold(
    uint64x2_t acc, uint64x2_t block, poly64_t k0, poly64_t k1) {
    const poly128_t low = vmull_p64((poly64_t)vgetq_lane_u64(acc, 0), k0);
    const poly128_t high = vmull_p64((poly64_t)vgetq_lane_u64(acc, 1), k1);
    return veorq_u64(veorq_u64(vreinterpretq_u64_p128(low), vreinterpretq_u64_p128(high)), block);
}
#endif

// The eight accumulators (16 bytes apart, in order) merged into one by 16-byte folds. A chain: a tree three folds deep (with
// 32- and 64-byte constants) measured equal on chunks and 4 to 8% slower on single 256-byte and 1 KiB inputs.
__attribute__((target("+aes"), always_inline)) static inline uint64x2_t crc_merge8(uint64x2_t a0, uint64x2_t a1, uint64x2_t a2,
    uint64x2_t a3, uint64x2_t a4, uint64x2_t a5, uint64x2_t a6, uint64x2_t a7) {
    const poly64_t m0 = 0xf20c0dfeu, m1 = 0x493c7d27u;
    uint64x2_t merged = crc_fold(a0, a1, m0, m1);
    merged = crc_fold(merged, a2, m0, m1);
    merged = crc_fold(merged, a3, m0, m1);
    merged = crc_fold(merged, a4, m0, m1);
    merged = crc_fold(merged, a5, m0, m1);
    merged = crc_fold(merged, a6, m0, m1);
    return crc_fold(merged, a7, m0, m1);
}

// The eight accumulators are written out, not an array in a loop: at -Os (a release build) the compiler neither unrolls
// the loop nor keeps an array in registers, and the fold fell to 20 GB/s.
#define CRC_LOAD(n) vreinterpretq_u64_u8(vld1q_u8(buf + 16 * (n)))
__attribute__((target("+crc+aes"))) static uint32_t crc_fold8(uint32_t crc, const uint8_t *buf, size_t len) {
    const poly64_t k0 = 0x6992cea2u, k1 = 0x0d3b6092u;
    uint64x2_t a0 = veorq_u64(CRC_LOAD(0), vsetq_lane_u64((uint64_t)crc, vdupq_n_u64(0), 0));
    uint64x2_t a1 = CRC_LOAD(1), a2 = CRC_LOAD(2), a3 = CRC_LOAD(3), a4 = CRC_LOAD(4), a5 = CRC_LOAD(5);
    uint64x2_t a6 = CRC_LOAD(6), a7 = CRC_LOAD(7);
    buf += 128;
    len -= 128;
    for (; len >= 128; buf += 128, len -= 128) {
        a0 = crc_fold(a0, CRC_LOAD(0), k0, k1);
        a1 = crc_fold(a1, CRC_LOAD(1), k0, k1);
        a2 = crc_fold(a2, CRC_LOAD(2), k0, k1);
        a3 = crc_fold(a3, CRC_LOAD(3), k0, k1);
        a4 = crc_fold(a4, CRC_LOAD(4), k0, k1);
        a5 = crc_fold(a5, CRC_LOAD(5), k0, k1);
        a6 = crc_fold(a6, CRC_LOAD(6), k0, k1);
        a7 = crc_fold(a7, CRC_LOAD(7), k0, k1);
    }
    const uint64x2_t merged = crc_merge8(a0, a1, a2, a3, a4, a5, a6, a7);
    uint32_t folded = __crc32cd(0, vgetq_lane_u64(merged, 0));
    folded = __crc32cd(folded, vgetq_lane_u64(merged, 1));
    return crc_words(folded, buf, len);
}

// The hybrid (corsix/fast-crc32's `v9s3x2e` idea, MacFS roadmap 0029): the vector fold leaves the integer pipes idle, so three
// `crc32cx` streams run beside it in the same loop over their own regions. A chunk is [V | S0 | S1 | S2]: the fold takes V,
// 128 bytes an iteration, each stream 16 bytes of its S, and at the end each part is moved into place by
// shift(v, n) = crc32cx(0, pmull(v, x^(8n-33) mod P)) (the identity of MacFS's docs/research/2026-10-30-neon-kernels.md), the
// three products xored before one reduction. The shift constants are x^(8n-33) mod P, bit-reflected, for n = 384, 768 and
// 1152 (and 4096 below); a wrong one fails every check, since no chunk would add up.
//
// The constants need fixed region sizes, so a chunk is fixed at 4096 bytes (23 iterations, then 2 more words a stream), the
// block Btrfs and ext4 checksum. Each chunk starts from 0 and the running value is moved past it by one shift, so chunks do
// not wait on each other: 78 GB/s on 64 KiB in cache with each chunk seeded by the last, 90 so. Larger chunks were as fast in
// cache but fell from DRAM (64 KiB: 43, 16 KiB: 38, against the memory's 59 that 4 KiB holds): their streams lie kilobytes
// apart (aemi diary 2026-10-30-03).
#define CRC_HYBRID_4K_ITERS 23
#define CRC_HYBRID_4K_EXTRA 2

__attribute__((target("+crc+aes"), always_inline)) static inline uint64_t crc_clmul32(uint32_t a, uint32_t k) {
    return vgetq_lane_u64(vreinterpretq_u64_p128(vmull_p64((poly64_t)a, (poly64_t)k)), 0);
}

__attribute__((target("+crc+aes"), always_inline)) static inline uint32_t crc_hybrid_chunk(
    uint32_t crc, const uint8_t *buf, size_t iters, size_t extra, uint32_t k3, uint32_t k2, uint32_t k1) {
    const size_t stream = 16 * iters + 8 * extra;
    const uint8_t *s0 = buf + 128 * iters, *s1 = s0 + stream, *s2 = s1 + stream;
    const poly64_t f0 = 0x6992cea2u, f1 = 0x0d3b6092u;
    uint32_t c0 = 0, c1 = 0, c2 = 0;
    uint64x2_t a0 = veorq_u64(CRC_LOAD(0), vsetq_lane_u64((uint64_t)crc, vdupq_n_u64(0), 0));
    uint64x2_t a1 = CRC_LOAD(1), a2 = CRC_LOAD(2), a3 = CRC_LOAD(3), a4 = CRC_LOAD(4), a5 = CRC_LOAD(5);
    uint64x2_t a6 = CRC_LOAD(6), a7 = CRC_LOAD(7);
    buf += 128;
    for (size_t i = 1; i < iters; ++i, buf += 128, s0 += 16, s1 += 16, s2 += 16) {
        uint64_t w[6];
        memcpy(&w[0], s0, 8); memcpy(&w[1], s0 + 8, 8);
        memcpy(&w[2], s1, 8); memcpy(&w[3], s1 + 8, 8);
        memcpy(&w[4], s2, 8); memcpy(&w[5], s2 + 8, 8);
        c0 = __crc32cd(c0, w[0]);
        c1 = __crc32cd(c1, w[2]);
        c2 = __crc32cd(c2, w[4]);
        a0 = crc_fold(a0, CRC_LOAD(0), f0, f1);
        a1 = crc_fold(a1, CRC_LOAD(1), f0, f1);
        a2 = crc_fold(a2, CRC_LOAD(2), f0, f1);
        a3 = crc_fold(a3, CRC_LOAD(3), f0, f1);
        c0 = __crc32cd(c0, w[1]);
        c1 = __crc32cd(c1, w[3]);
        c2 = __crc32cd(c2, w[5]);
        a4 = crc_fold(a4, CRC_LOAD(4), f0, f1);
        a5 = crc_fold(a5, CRC_LOAD(5), f0, f1);
        a6 = crc_fold(a6, CRC_LOAD(6), f0, f1);
        a7 = crc_fold(a7, CRC_LOAD(7), f0, f1);
    }
    // The streams' last iteration (the fold's first was the initial load) and their extra words.
    for (size_t i = 0; i < 2 + extra; ++i, s0 += 8, s1 += 8, s2 += 8) {
        uint64_t x, y, z;
        memcpy(&x, s0, 8); memcpy(&y, s1, 8); memcpy(&z, s2, 8);
        c0 = __crc32cd(c0, x);
        c1 = __crc32cd(c1, y);
        c2 = __crc32cd(c2, z);
    }
    const uint64x2_t merged = crc_merge8(a0, a1, a2, a3, a4, a5, a6, a7);
    uint32_t v = __crc32cd(0, vgetq_lane_u64(merged, 0));
    v = __crc32cd(v, vgetq_lane_u64(merged, 1));
    return __crc32cd(0, crc_clmul32(v, k3) ^ crc_clmul32(c0, k2) ^ crc_clmul32(c1, k1)) ^ c2;
}

__attribute__((target("+crc+aes"))) static uint32_t crc_hybrid(uint32_t crc, const uint8_t *buf, size_t len) {
    // crc(c, B) = shift(c, |B|) ^ crc(0, B): one chunk's merge overlaps the next one's loop.
    for (; len >= 4096; buf += 4096, len -= 4096) {
        const uint32_t chunk = crc_hybrid_chunk(
            0, buf, CRC_HYBRID_4K_ITERS, CRC_HYBRID_4K_EXTRA, 0x86d8e4d2u, 0xd7a4825cu, 0xd270f1a2u);
        crc = __crc32cd(0, crc_clmul32(crc, 0x82f89c77u)) ^ chunk;
    }
    return len >= 256 ? crc_fold8(crc, buf, len) : crc_words(crc, buf, len);
}
#undef CRC_LOAD
#endif

#if defined(__x86_64__)
__attribute__((target("sse4.2"))) static uint32_t crc_sse42(uint32_t crc, const uint8_t *buf, size_t len) {
    uint64_t state = crc;
    for (; len >= 8; buf += 8, len -= 8) {
        uint64_t word;
        memcpy(&word, buf, 8);
        state = _mm_crc32_u64(state, word);
    }
    uint32_t narrow = (uint32_t)state;
    for (; len > 0; ++buf, --len) {
        narrow = _mm_crc32_u8(narrow, *buf);
    }
    return narrow;
}
#endif

#if defined(__aarch64__) && !(defined(__ARM_FEATURE_CRC32) && defined(__ARM_FEATURE_AES))
// Without the features on the command line the dispatcher is built without `+crc`, so the always-inline `crc_words` cannot be
// inlined into it: this call carries the feature (found by `checksum-kernels-check.sh --linux`).
__attribute__((target("+crc"))) static uint32_t crc_words_call(uint32_t crc, const uint8_t *buf, size_t len) {
    return crc_words(crc, buf, len);
}
#endif

uint32_t adf_crc32c_update(uint32_t crc, const uint8_t *buf, size_t len) {
#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32) && defined(__ARM_FEATURE_AES)
    // Every Apple arm64 target (and any built for a CPU that has both) guarantees the instructions at compile time:
    // no runtime lookup, which cost about two nanoseconds a call, more than the CRC of a short name.
    // Short inputs first (names, descriptors, inodes) and inline: their cost is the calls around them.
    if (len < 256) {
        return crc_words(crc, buf, len);
    }
    return len >= 4096 ? crc_hybrid(crc, buf, len) : crc_fold8(crc, buf, len);
#elif defined(__aarch64__)
    if (adf_kernels_has_crc32_pmull()) {
        return len >= 4096 ? crc_hybrid(crc, buf, len) : len >= 256 ? crc_fold8(crc, buf, len) : crc_words_call(crc, buf, len);
    }
#elif defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_SSE42) {
        return crc_sse42(crc, buf, len);
    }
#endif
    return adf_crc32c_update_scalar(crc, buf, len);
}
