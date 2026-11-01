//
//  CAemiArgon2.h
//  CAemiArgon2
//
//  Argon2's memory fill and block function G (RFC 9106), BLAKE2b's compression (RFC 7693), a constant-time comparison
//  and a wipe the compiler may not remove, behind the Swift `AemiArgon2`. Each kernel has a portable scalar reference
//  (the differential oracle) and the fastest backend this CPU has: NEON, NEON with SHA3's `xar` (rotate after xor in one
//  instruction; compile-time on Apple silicon, detected at run time elsewhere), SSSE3 or AVX2 on x86-64. A backend asked
//  for by name runs only when the CPU has it; otherwise the next one down does (`adf_crypto_resolve`).
//
//  Timing: no kernel branches on, or indexes a table by, a secret. What Argon2 itself reveals is its memory access
//  pattern where the variant reads blocks chosen by the data (Argon2d, and Argon2id after its first half pass), which
//  is inherent to the algorithm and why Argon2id begins data-independently (RFC 9106, 3.4).
//

#ifndef CAEMIARGON2_H
#define CAEMIARGON2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The backends, in no order of speed. `ADF_CRYPTO_FASTEST` picks the best this CPU runs.
typedef enum {
    ADF_CRYPTO_FASTEST = 0,
    ADF_CRYPTO_SCALAR = 1,
    ADF_CRYPTO_NEON = 2,
    ADF_CRYPTO_NEON_SHA3 = 3,
    ADF_CRYPTO_SSSE3 = 4,
    ADF_CRYPTO_AVX2 = 5
} adf_crypto_backend_t;

/// The backend that runs when `requested` is asked for: itself when this CPU has it, else the best one below it.
int adf_crypto_resolve(int requested);

/// A name for a backend, for tests and benchmarks: "scalar", "neon", "neon+sha3", "ssse3", "avx2".
const char *adf_crypto_backend_name(int backend);

/// Argon2's G over 1024-byte blocks of 128 little-endian words: `next = G(prev, ref)`, or `next ^= G(prev, ref)` when
/// `with_xor` is nonzero (a pass after the first, version 0x13). `next` may not overlap `prev` or `ref`.
void adf_argon2_block(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor, int backend);

/// What `adf_argon2_fill` fills: `lanes * lane_length` blocks, the first two of each lane already written (RFC 9106,
/// 3.2, steps 3 and 4). `lane_length` is a multiple of 4 and at least 8; `type` is 0 for Argon2d, 1 for Argon2i, 2 for
/// Argon2id.
typedef struct {
    uint64_t *memory;
    uint32_t lanes;
    uint32_t lane_length;
    uint32_t passes;
    uint32_t type;
    /// Threads to fill the lanes of a slice with, 1 or more; the result does not depend on it.
    uint32_t threads;
    int backend;
} adf_argon2_fill_t;

/// Runs every pass over the memory (RFC 9106, 3.2, steps 5 and 6). Threads that cannot be started leave their lanes
/// to the calling thread, so the fill always completes.
void adf_argon2_fill(const adf_argon2_fill_t *fill);

/// BLAKE2b's F over one block of 16 little-endian words: `count` the bytes so far (128 bits, low word first), `last`
/// nonzero for the final block.
void adf_blake2b_compress(uint64_t state[8], const uint64_t block[16], uint64_t count_low, uint64_t count_high,
                          int last, int backend);

/// 1 when the `length` bytes at `a` and `b` are equal, 0 otherwise, in a time that depends on `length` only.
int adf_crypto_equal(const uint8_t *a, const uint8_t *b, size_t length);

/// Zeroes `length` bytes at `bytes` in a way the compiler may not remove as a dead store.
void adf_crypto_wipe(void *bytes, size_t length);

/// `blocks` blocks of 1024 bytes aligned to a cache line, or NULL when the memory is not there. Freed by
/// `adf_argon2_release`, which wipes them first.
uint64_t *adf_argon2_allocate(size_t blocks);
void adf_argon2_release(uint64_t *memory, size_t blocks);

#ifdef __cplusplus
}
#endif

#endif
