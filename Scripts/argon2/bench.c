// Argon2's fill per backend at OWASP's minimum for Argon2id (19 MiB, 2 passes), on 1 lane and on 4 lanes with 4 threads,
// and G's throughput with data-independent timing off and on. Built at -O3 by check.sh --bench.
#include "CAemiArgon2.h"
#include "CAemiCPU.h"
#include "../../Sources/CAemiArgon2/adf_argon2_internal.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static double seconds(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

static double fill_ms(int backend, uint32_t lanes, uint32_t threads) {
    const uint32_t lane_length = 19456 / lanes;
    uint64_t *memory = adf_argon2_allocate((size_t)lanes * lane_length);
    memset(memory, 1, (size_t)lanes * lane_length * 1024);
    double best = 1e9;
    for (int run = 0; run < 7; run++) {
        adf_argon2_fill_t fill = {memory, lanes, lane_length, 2, 2, threads, backend};
        const double start = seconds();
        adf_argon2_fill(&fill);
        const double elapsed = seconds() - start;
        if (elapsed < best) best = elapsed;
    }
    adf_argon2_release(memory, (size_t)lanes * lane_length);
    return best * 1000;
}

static double block_ns(adf_argon2_block_fn block, int dit) {
    static uint64_t a[128], b[128], c[128];
    double best = 1e9;
    for (int run = 0; run < 5; run++) {
        const adf_timing_token_t token = dit ? adf_cpu_timing_safe_begin() : 0;
        const double start = seconds();
        for (int i = 0; i < 200000; i++) block(c, a, b, i & 1);
        const double elapsed = seconds() - start;
        if (dit) adf_cpu_timing_safe_end(token);
        if (elapsed < best) best = elapsed;
    }
    return best / 200000 * 1e9;
}

int main(void) {
    printf("  %-10s %12s %16s %12s %12s\n", "backend", "p=1 ms", "p=4 4 threads", "G ns", "G ns (DIT)");
    for (int backend = ADF_CRYPTO_SCALAR; backend <= ADF_CRYPTO_AVX2; backend++) {
        if (adf_crypto_resolve(backend) != backend) continue;
        const adf_argon2_block_fn block = adf_argon2_block_function(backend);
        printf("  %-10s %12.2f %16.2f %12.1f %12.1f\n", adf_crypto_backend_name(backend), fill_ms(backend, 1, 1),
               fill_ms(backend, 4, 4), block_ns(block, 0), block_ns(block, 1));
    }
    return 0;
}
