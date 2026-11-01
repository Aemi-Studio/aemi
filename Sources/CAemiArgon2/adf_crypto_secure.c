//
//  adf_crypto_secure.c
//  CAemiArgon2
//
//  A comparison whose time depends on the length only, a wipe the optimiser keeps, and Argon2's memory.
//

// mmap and MAP_ANON are POSIX and BSD; a strict C11 build on Linux hides them unless asked.
#if defined(__linux__)
#define _DEFAULT_SOURCE 1
#endif

#include "adf_argon2_internal.h"

#include <CAemiCPU.h>
#include <string.h>
#include <sys/mman.h>

int adf_crypto_equal(const uint8_t *a, const uint8_t *b, size_t length) {
    const adf_timing_token_t token = adf_cpu_timing_safe_begin();
    uint32_t difference = 0;
    for (size_t index = 0; index < length; index++) {
        difference |= (uint32_t)(a[index] ^ b[index]);
        // The barrier keeps the compiler from turning the loop into an early exit at the first difference.
        __asm__ volatile("" : "+r"(difference));
    }
    adf_cpu_timing_safe_end(token);
    return (int)(1u & ((difference - 1u) >> 8));
}

/// `memset` reached through a volatile pointer: the compiler cannot know which function it calls, so it cannot drop the
/// call as a store nothing reads; the barrier after it says the memory is used.
static void *(*const volatile adf_memset)(void *, int, size_t) = memset;

void adf_crypto_wipe(void *bytes, size_t length) {
    if (length == 0) {
        return;
    }
    (void)adf_memset(bytes, 0, length);
    __asm__ volatile("" : : "r"(bytes) : "memory");
}

uint64_t *adf_argon2_allocate(size_t blocks) {
    if (blocks == 0 || blocks > SIZE_MAX / 1024u) {
        return NULL;
    }
    // Mapped, not malloc'd: munmap gives the pages back to the system at once. A large malloc block, freed, stays resident for
    // reuse: measured in ask, the 19 MiB of a derivation still counted after it, against a 20 MiB budget. Page-aligned, which is
    // more than the cache line a block needs.
    void *memory = mmap(NULL, blocks * 1024u, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return memory == MAP_FAILED ? NULL : memory;
}

void adf_argon2_release(uint64_t *memory, size_t blocks) {
    if (memory == NULL) {
        return;
    }
    adf_crypto_wipe(memory, blocks * 1024u);
    (void)munmap(memory, blocks * 1024u);
}
