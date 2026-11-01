//
//  adf_argon2_fill.c
//  CAemiArgon2
//
//  RFC 9106, 3.2 steps 5 and 6, and 3.4: every pass, slice by slice, the lanes of a slice in parallel (they only read
//  blocks of finished slices and their own). Indexes are computed with no branch on the pseudo-random words: the
//  reference lane by a multiply-based remainder (Lemire's fastmod) rather than a division, whose time can depend on
//  its operands, and the area by masks. What remains secret-dependent in Argon2d and in Argon2id's later slices is
//  which block is read, which is the algorithm's own trade (RFC 9106, 3.4.1).
//

#include "adf_argon2_internal.h"

#include <CAemiCPU.h>
#include <pthread.h>
#include <string.h>

#define ADF_WORDS 128u
#define ADF_SYNC_POINTS 4u

__extension__ typedef unsigned __int128 adf_u128;

typedef struct {
    const adf_argon2_fill_t *fill;
    adf_argon2_block_fn block;
    uint64_t lane_modulus;
    uint32_t pass;
    uint32_t slice;
    uint32_t first_lane;
    uint32_t lane_step;
} adf_segment_job;

/// `value % divisor` for 32-bit values, `magic` being `UINT64_MAX / divisor + 1`: two multiplies, no division.
static inline uint32_t adf_fastmod(uint32_t value, uint64_t magic, uint32_t divisor) {
    const uint64_t low = magic * value;
    return (uint32_t)(((adf_u128)low * divisor) >> 64);
}

/// The next 128 data-independent pseudo-random words: G(0, G(0, input)) after counting the input up (RFC 9106, 3.4.2).
static void adf_next_addresses(adf_argon2_block_fn block, uint64_t *address, uint64_t *input, uint64_t *scratch) {
    static const uint64_t zero[ADF_WORDS];
    input[6] += 1;
    block(scratch, zero, input, 0);
    block(address, zero, scratch, 0);
}

/// The column referenced from block `index` of the segment (RFC 9106, 3.4.1.2), `same_lane` 1 or 0.
static inline uint32_t adf_reference_column(const adf_segment_job *job, uint32_t index, uint32_t pseudo_low,
                                            uint32_t same_lane) {
    const uint32_t segment = job->fill->lane_length / ADF_SYNC_POINTS;
    const uint32_t base = job->pass == 0 ? job->slice * segment : job->fill->lane_length - segment;
    const uint32_t mask = 0u - same_lane;
    // In the own lane, every finished block but the previous one; in another, that lane's finished slices, less one
    // when this is the segment's first block.
    const uint32_t own = index - 1u;
    const uint32_t other = index == 0 ? 0xFFFFFFFFu : 0u;
    const uint32_t area = base + ((own & mask) | (other & ~mask));
    uint64_t relative = pseudo_low;
    relative = (relative * relative) >> 32;
    relative = area - 1u - (((uint64_t)area * relative) >> 32);
    const uint32_t start = (job->pass == 0 || job->slice == ADF_SYNC_POINTS - 1) ? 0u : (job->slice + 1) * segment;
    const uint64_t column = start + relative;
    const uint64_t wrap = 0u - (uint64_t)(column >= job->fill->lane_length);
    return (uint32_t)(column - (job->fill->lane_length & wrap));
}

static void adf_fill_segment(const adf_segment_job *job, uint32_t lane) {
    const adf_argon2_fill_t *fill = job->fill;
    uint64_t *memory = fill->memory;
    const uint32_t segment = fill->lane_length / ADF_SYNC_POINTS;
    const int independent = fill->type == 1 || (fill->type == 2 && job->pass == 0 && job->slice < ADF_SYNC_POINTS / 2);
    uint64_t address[ADF_WORDS], input[ADF_WORDS], scratch[ADF_WORDS];
    if (independent) {
        memset(input, 0, sizeof input);
        input[0] = job->pass;
        input[1] = lane;
        input[2] = job->slice;
        input[3] = (uint64_t)fill->lanes * fill->lane_length;
        input[4] = fill->passes;
        input[5] = fill->type;
    }
    const uint32_t first = (job->pass == 0 && job->slice == 0) ? 2u : 0u;
    if (independent && first == 2) {
        adf_next_addresses(job->block, address, input, scratch);
    }
    const uint64_t lane_start = (uint64_t)lane * fill->lane_length;
    for (uint32_t index = first; index < segment; index++) {
        const uint32_t column = job->slice * segment + index;
        const uint32_t previous = column == 0 ? fill->lane_length - 1 : column - 1;
        uint64_t pseudo;
        if (independent) {
            if (index % ADF_WORDS == 0) {
                adf_next_addresses(job->block, address, input, scratch);
            }
            pseudo = address[index % ADF_WORDS];
        } else {
            pseudo = memory[(lane_start + previous) * ADF_WORDS];
        }
        const uint32_t own_only = job->pass == 0 && job->slice == 0;
        const uint32_t picked = adf_fastmod((uint32_t)(pseudo >> 32), job->lane_modulus, fill->lanes);
        const uint32_t own_mask = 0u - own_only;
        const uint32_t reference_lane = (lane & own_mask) | (picked & ~own_mask);
        const uint32_t same_lane = (uint32_t)(reference_lane == lane);
        const uint32_t reference = adf_reference_column(job, index, (uint32_t)pseudo, same_lane);
        job->block(memory + (lane_start + column) * ADF_WORDS, memory + (lane_start + previous) * ADF_WORDS,
                   memory + ((uint64_t)reference_lane * fill->lane_length + reference) * ADF_WORDS, job->pass != 0);
    }
    adf_crypto_wipe(address, sizeof address);
    adf_crypto_wipe(input, sizeof input);
    adf_crypto_wipe(scratch, sizeof scratch);
}

/// One thread's lanes of a slice; data-independent timing is per thread, so each worker sets its own.
static void *adf_fill_lanes(void *argument) {
    const adf_segment_job *job = argument;
    const adf_timing_token_t token = adf_cpu_timing_safe_begin();
    for (uint32_t lane = job->first_lane; lane < job->fill->lanes; lane += job->lane_step) {
        adf_fill_segment(job, lane);
    }
    adf_cpu_timing_safe_end(token);
    return NULL;
}

void adf_argon2_fill(const adf_argon2_fill_t *fill) {
    const uint32_t workers = fill->threads < 1 ? 1 : (fill->threads > fill->lanes ? fill->lanes : fill->threads);
    enum { most_workers = 64 };
    const uint32_t count = workers > most_workers ? most_workers : workers;
    adf_segment_job jobs[most_workers];
    pthread_t threads[most_workers];
    int started[most_workers];
    const adf_argon2_block_fn block = adf_argon2_block_function(fill->backend);
    const uint64_t modulus = UINT64_MAX / fill->lanes + 1;
    for (uint32_t pass = 0; pass < fill->passes; pass++) {
        for (uint32_t slice = 0; slice < ADF_SYNC_POINTS; slice++) {
            for (uint32_t worker = 0; worker < count; worker++) {
                jobs[worker] = (adf_segment_job){fill, block, modulus, pass, slice, worker, count};
            }
            for (uint32_t worker = 1; worker < count; worker++) {
                started[worker] = pthread_create(&threads[worker], NULL, adf_fill_lanes, &jobs[worker]) == 0;
            }
            adf_fill_lanes(&jobs[0]);
            for (uint32_t worker = 1; worker < count; worker++) {
                if (started[worker]) {
                    pthread_join(threads[worker], NULL);
                } else {
                    adf_fill_lanes(&jobs[worker]);
                }
            }
        }
    }
}
