//
//  CAemiKernels.h
//  CAemiKernels
//
//  Runtime-dispatched SIMD byte kernels for the AD* family, behind the pure-Swift `AemiKernels`
//  facade. Each public kernel picks the widest ISA available on THIS CPU at runtime (detected once
//  and cached): AVX2 / SSE4.2 / SSE2 on x86-64, NEON on arm64, portable scalar elsewhere. Every
//  backend agrees byte-for-byte with the portable scalar reference (the differential-test oracle),
//  and every explicitly-named backend self-guards: it falls back to a supported path when its CPU
//  feature is unavailable, so a test may call e.g. `_avx2` on an arm64 host without trapping.
//
//  Design mirrors HTTP's `CCRC32` (per-function `__attribute__((target(...)))` + `pthread_once`
//  one-time init), extended with the RUNTIME feature probe that CCRC32 omits (it assumes ARMv8 CRC).
//

#ifndef CADFKERNELS_H
#define CADFKERNELS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - CPU feature tier

/// The ISA tiers a kernel can dispatch to, in ascending capability. The x86 and arm64 ladders are
/// disjoint; `adf_kernels_isa()` returns exactly one, resolved once per process from the host CPU.
typedef enum {
    ADF_ISA_SCALAR = 0,   ///< No SIMD (unknown arch, or a deliberately-forced scalar run).
    ADF_ISA_X86_SSE2,     ///< x86-64 baseline (always present on x86-64).
    ADF_ISA_X86_SSE42,    ///< + SSSE3/SSE4.2 (pshufb, byte compares). Rosetta 2 tops out here.
    ADF_ISA_X86_AVX2,     ///< + AVX2 + BMI2 (256-bit lanes).
    ADF_ISA_X86_AVX512,   ///< + AVX-512F/BW (512-bit lanes; length-gated, opt-in).
    ADF_ISA_ARM_NEON,     ///< arm64 baseline (AdvSIMD, always present on arm64).
    ADF_ISA_ARM_DOTPROD,  ///< + FEAT_DotProd.
    ADF_ISA_ARM_I8MM      ///< + FEAT_I8MM (absent on Apple M1).
} adf_isa_t;

/// The ISA tier selected for this CPU. Resolved once (thread-safe via `pthread_once`) and cached;
/// subsequent calls are a plain load. Value is one of `adf_isa_t`.
int adf_kernels_isa(void);

/// A human-readable name of the selected tier (for logging / benchmarks), e.g. "avx2", "neon+dotprod".
const char *adf_kernels_backend(void);

// MARK: - ASCII fold (A–Z → a–z)

/// Copy `src[0..<len]` into `dst`, lowercasing ASCII uppercase (0x41–0x5A) and leaving every other
/// byte (including non-ASCII) unchanged. `dst` may equal `src` (in-place); otherwise the ranges must
/// not overlap. Picks the widest available backend.
void adf_fold_ascii(uint8_t *dst, const uint8_t *src, size_t len);

/// Named backends — each self-guards (falls back if its feature is absent). For differential tests.
void adf_fold_ascii_scalar(uint8_t *dst, const uint8_t *src, size_t len);
void adf_fold_ascii_sse2(uint8_t *dst, const uint8_t *src, size_t len);
void adf_fold_ascii_avx2(uint8_t *dst, const uint8_t *src, size_t len);
void adf_fold_ascii_neon(uint8_t *dst, const uint8_t *src, size_t len);

// MARK: - JSON-style string-stop scan

/// Index of the first byte in `buf[0..<len]` that a JSON/wire string scanner must stop on — i.e. the
/// first byte that is NOT a "plain" ASCII content byte. A byte `b` is plain iff
/// `0x20 <= b <= 0x7F && b != quote && b != escape`; the scan stops on any control byte (`b < 0x20`),
/// any non-ASCII byte (`b >= 0x80`), the `quote`, or the `escape`. Returns `len` if the whole buffer
/// is plain content. This matches ADJSON's `stringStopMask` (`lessThan(0x20) | nonASCII | ==quote |
/// ==escape`). Picks the widest available backend.
size_t adf_index_of_string_stop(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape);

/// Named backends — each self-guards. For differential tests.
size_t adf_index_of_string_stop_scalar(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape);
size_t adf_index_of_string_stop_sse2(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape);
size_t adf_index_of_string_stop_avx2(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape);
size_t adf_index_of_string_stop_neon(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape);

// MARK: - First byte in a small literal set

/// Index of the first byte in `buf[0..<len]` equal to any of `n0..n4`, or `len` if none. Repeat a
/// needle to use fewer than five (e.g. pass `n3 = n4 = n0` for a 3-byte set). The primitive an HTML
/// escaper uses to jump to the next `& < >` (+ `" '`). Picks the widest available backend.
size_t adf_index_of_any5(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4);
size_t adf_index_of_any5_scalar(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4);

// MARK: - First non-ASCII byte (ASCII-run skip)

/// Index of the first byte in `buf[0..<len]` with the high bit set (`>= 0x80`), or `len` if every
/// byte is ASCII. The primitive an incremental UTF-8 validator uses to skip long ASCII runs before
/// falling to per-scalar multi-byte checking. Picks the widest available backend.
size_t adf_index_of_nonascii(const uint8_t *buf, size_t len);
size_t adf_index_of_nonascii_scalar(const uint8_t *buf, size_t len);
size_t adf_index_of_nonascii_sse2(const uint8_t *buf, size_t len);
size_t adf_index_of_nonascii_avx2(const uint8_t *buf, size_t len);
size_t adf_index_of_nonascii_neon(const uint8_t *buf, size_t len);

// MARK: - Printable-text validation (control/DEL illegal, obs-text allowed)

/// Index of the first byte in `buf[0..<len]` that is NOT legal printable wire text, or `len` if all
/// legal. A byte is ILLEGAL iff it is a control byte below `min_allowed` (with an optional HTAB `0x09`
/// exception when `allow_tab`) OR it is DEL `0x7F`. Bytes `>= 0x80` (obs-text) are always legal.
/// RFC 9110 field-value: `min_allowed = 0x20, allow_tab = 1`; request-target: `0x21, 0`. Widest backend.
size_t adf_first_disallowed_text(const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab);
size_t adf_first_disallowed_text_scalar(
    const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab);

// MARK: - First control byte or literal (JSON escape-on-write scan)

/// Index of the first byte in `buf[0..<len]` that is a control byte (`< 0x20`) OR equal to any of
/// `n0..n4` (repeat a needle to use fewer), or `len` if none. Bytes `>= 0x80` are NOT stops (a JSON
/// serializer copies well-formed UTF-8 verbatim). The escape-on-write scan: `n0 = quote`, `n1 =
/// escape`, plus optional `/` and the HTML-unsafe `< > &`. Widest backend.
size_t adf_index_of_control_or_any5(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4);
size_t adf_index_of_control_or_any5_scalar(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4);

// MARK: - Full UTF-8 validation (multibyte in-vector, simdjson/Lemire)

/// Byte offset of the first byte that is NOT part of well-formed UTF-8 (RFC 3629 — rejects invalid
/// leads, bad/short continuations, overlong encodings, surrogates U+D800–U+DFFF, and > U+10FFFF), or
/// `len` if the whole buffer is well-formed. Unlike an ASCII-skip validator this validates multi-byte
/// sequences IN-VECTOR (16/32 bytes per step) rather than one scalar at a time. Widest backend; the
/// exact first-invalid offset is found by a scalar rescan only on the (rare) invalid path.
size_t adf_first_invalid_utf8(const uint8_t *buf, size_t len);
size_t adf_first_invalid_utf8_scalar(const uint8_t *buf, size_t len);

// MARK: - Hamming distance (popcount of XOR) — bit-vector similarity

/// The number of differing bits between `a[0..<len]` and `b[0..<len]` — `Σ popcount(a[i] ^ b[i])`, the
/// KNN / sign-quantized-embedding similarity primitive. The result is an exact integer, so every
/// backend (NEON `cnt`, x86 `popcnt`, scalar) returns the identical value. Widest backend.
size_t adf_hamming_distance(const uint8_t *a, const uint8_t *b, size_t len);
size_t adf_hamming_distance_scalar(const uint8_t *a, const uint8_t *b, size_t len);

/// Batched Hamming scan: for each of `count` `width`-byte vectors packed contiguously in `corpus`,
/// write its Hamming distance to `query` into `out[i]`. One runtime dispatch for the whole scan and
/// the query stays hot — the KNN-shortlist primitive (amortizes the per-call cost a single-pair loop
/// pays at small widths). `out` must hold `count` `uint32_t`s.
void adf_hamming_scan(
    const uint8_t *query, const uint8_t *corpus, size_t width, size_t count, uint32_t *out);

// MARK: - Date parsing (byte-level, Foundation-free)

/// Parse the canonical UTC ISO-8601 timestamp `YYYY-MM-DDTHH:MM:SSZ` (exactly `len == 20` bytes) in
/// `buf` into seconds since the Unix epoch (1970-01-01 UTC), written to `*out`. Returns 1 on success, or
/// 0 to DEFER — for any other length/shape, an out-of-range field, a non-canonical spelling, the 1582
/// Gregorian-reform year, or a year < 1 — so the caller (which has a full date library) falls back and
/// the pair stays byte-identical to that library. Julian calendar before the 1582-10-15 reform,
/// Gregorian on/after (matching Foundation's `.iso8601`). Scalar: a fixed 20-byte parse does not amortize
/// a per-call SIMD dispatch, so this is tight portable C the compiler lowers to optimal arm64 / x86-64.
int adf_parse_iso8601_utc(const uint8_t *buf, size_t len, int64_t *out);

// MARK: - Single-byte search

/// Index of the first byte in `buf[0..<len]` equal to `needle`, or `len` if absent. Routes to the
/// platform `memchr` (already vectorized in libc); the `_scalar` variant is the plain reference.
size_t adf_index_of_byte(const uint8_t *buf, size_t len, uint8_t needle);
size_t adf_index_of_byte_scalar(const uint8_t *buf, size_t len, uint8_t needle);

#ifdef __cplusplus
}
#endif

#endif /* CADFKERNELS_H */
