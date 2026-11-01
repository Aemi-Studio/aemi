//
//  adf_argon2_internal.h
//  CAemiArgon2
//
//  Declarations shared between the backends' files; not part of the module's interface.
//

#ifndef ADF_ARGON2_INTERNAL_H
#define ADF_ARGON2_INTERNAL_H

#include "CAemiArgon2.h"

/// RFC 9106's G as each backend computes it.
void adf_argon2_block_scalar(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor);
void adf_argon2_block_neon(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor);
void adf_argon2_block_neon_sha3(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor);
void adf_argon2_block_ssse3(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor);
void adf_argon2_block_avx2(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor);

void adf_blake2b_compress_scalar(uint64_t state[8], const uint64_t block[16], uint64_t count_low, uint64_t count_high,
                                 int last);
void adf_blake2b_compress_neon(uint64_t state[8], const uint64_t block[16], uint64_t count_low, uint64_t count_high,
                               int last, int sha3);

typedef void (*adf_argon2_block_fn)(uint64_t *, const uint64_t *, const uint64_t *, int);

/// The block function a resolved backend uses.
adf_argon2_block_fn adf_argon2_block_function(int backend);

#endif
