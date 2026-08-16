#include "CAemiTestKitMalloc.h"

#if defined(__APPLE__)

#include <stdatomic.h>

/// libsystem_malloc's global logging hook. When non-NULL, libmalloc invokes it on every
/// allocate / free / realloc. Declared here (it lives in a private header) — valid for the
/// test/tooling builds this target serves.
typedef void(adtk_malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                                   uintptr_t result, uint32_t num_hot_frames_to_skip);
extern adtk_malloc_logger_t *malloc_logger;

/// `MALLOC_LOG_TYPE_ALLOCATE` in libmalloc's stack-logging encoding (a malloc/calloc/realloc-new).
#define ADTK_MALLOC_LOG_TYPE_ALLOCATE 2

static _Atomic(uint64_t) adtk_alloc_count = 0;
static adtk_malloc_logger_t *adtk_prev_logger = 0;
static int adtk_active = 0;

static void adtk_counting_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                                 uintptr_t result, uint32_t num_hot_frames_to_skip) {
    if (type & ADTK_MALLOC_LOG_TYPE_ALLOCATE) {
        atomic_fetch_add_explicit(&adtk_alloc_count, 1, memory_order_relaxed);
    }
    /* Chain to whatever hook was already installed (e.g. Instruments) so we don't disrupt it. The
       counting hook itself must not allocate — it does not. */
    if (adtk_prev_logger) {
        adtk_prev_logger(type, arg1, arg2, arg3, result, num_hot_frames_to_skip);
    }
}

int adtk_malloc_counting_available(void) { return 1; }

void adtk_malloc_count_begin(void) {
    atomic_store_explicit(&adtk_alloc_count, 0, memory_order_relaxed);
    adtk_prev_logger = malloc_logger;
    adtk_active = 1;
    malloc_logger = adtk_counting_logger;
}

uint64_t adtk_malloc_count_end(void) {
    if (!adtk_active) {
        return 0;
    }
    malloc_logger = adtk_prev_logger;
    adtk_active = 0;
    return atomic_load_explicit(&adtk_alloc_count, memory_order_relaxed);
}

#else /* non-Darwin: counting unavailable — the ordo-one benchmark malloc metric covers Linux CI. */

int adtk_malloc_counting_available(void) { return 0; }
void adtk_malloc_count_begin(void) {}
uint64_t adtk_malloc_count_end(void) { return 0; }

#endif
