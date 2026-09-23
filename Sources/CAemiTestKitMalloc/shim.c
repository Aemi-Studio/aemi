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

/* Shared between `begin`/`end` and the hook, which runs on whichever thread allocates: every access
   is atomic, so none of them races. Relaxed is enough — the only value published is the hook to chain
   to, and any value the hook can read (NULL, or a hook found installed at some `begin`) is valid. */
static _Atomic(uint64_t) adtk_alloc_count = 0;
static _Atomic(adtk_malloc_logger_t *) adtk_prev_logger = 0;
static _Atomic(int) adtk_active = 0;

static void adtk_counting_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                                 uintptr_t result, uint32_t num_hot_frames_to_skip) {
    if (type & ADTK_MALLOC_LOG_TYPE_ALLOCATE) {
        atomic_fetch_add_explicit(&adtk_alloc_count, 1, memory_order_relaxed);
    }
    /* Chain to whatever hook was already installed (e.g. Instruments) so we don't disrupt it. The
       counting hook itself must not allocate — it does not. */
    adtk_malloc_logger_t *prev = atomic_load_explicit(&adtk_prev_logger, memory_order_relaxed);
    if (prev) {
        prev(type, arg1, arg2, arg3, result, num_hot_frames_to_skip);
    }
}

int adtk_malloc_counting_available(void) { return 1; }

void adtk_malloc_count_begin(void) {
    adtk_malloc_logger_t *current = __atomic_load_n(&malloc_logger, __ATOMIC_RELAXED);
    /* Already counting (an overlapping `begin`): saving our own hook as the one to chain to would make
       it call itself on every allocation until the stack overflows, so keep the chain as it is. */
    if (current == adtk_counting_logger) {
        return;
    }
    atomic_store_explicit(&adtk_alloc_count, 0, memory_order_relaxed);
    atomic_store_explicit(&adtk_prev_logger, current, memory_order_relaxed);
    atomic_store_explicit(&adtk_active, 1, memory_order_relaxed);
    __atomic_store_n(&malloc_logger, adtk_counting_logger, __ATOMIC_RELAXED);
}

uint64_t adtk_malloc_count_end(void) {
    if (!atomic_exchange_explicit(&adtk_active, 0, memory_order_relaxed)) {
        return 0;
    }
    __atomic_store_n(
        &malloc_logger, atomic_load_explicit(&adtk_prev_logger, memory_order_relaxed), __ATOMIC_RELAXED);
    return atomic_load_explicit(&adtk_alloc_count, memory_order_relaxed);
}

#else /* non-Darwin: counting unavailable — the ordo-one benchmark malloc metric covers Linux CI. */

int adtk_malloc_counting_available(void) { return 0; }
void adtk_malloc_count_begin(void) {}
uint64_t adtk_malloc_count_end(void) { return 0; }

#endif
