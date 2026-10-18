#ifndef CADTESTKIT_MALLOC_H
#define CADTESTKIT_MALLOC_H

#include <stdint.h>

/// Heap-allocation counting for test perf guards (e.g. AemiTestKit's `expectAllocations`).
///
/// On Darwin this installs libmalloc's logging hook (`malloc_logger`) — a documented-in-practice
/// tooling seam Instruments uses. It is enabled only in TEST / tooling builds and never ships in an
/// App-Store binary, so the private symbol is acceptable here. On other platforms the counter is a
/// no-op and `adtk_malloc_counting_available()` returns 0, so the Swift oracle degrades gracefully.
///
/// Only the thread that called `begin` is counted. The hook itself sees other threads: measured on
/// 2026-10-18, a fresh thread making 10,000 allocations inside a window added 10,008 to its count, and
/// parallel test suites pushed a lexer ceiling of 4 to a minimum of 191 over 64 samples. Restricting
/// the count to the opening thread makes a ceiling fail only for its own body's allocations.
///
/// Consequence: work the measured body hands to another thread is not counted. Measure a SYNCHRONOUS,
/// single-threaded body. On that thread the count is exact: 1,000 mallocs count 1,000, and a body
/// that allocates nothing counts 0. Measurements must not overlap — AemiTestKit's `mallocDelta`
/// serializes them. A `begin` while the hook is already installed is ignored rather than chaining
/// the hook to itself.

/// 1 when allocation counting is available on this platform (Darwin), 0 otherwise.
int adtk_malloc_counting_available(void);

/// Reset the counter, record the calling thread as the one to count, and install the counting hook
/// (chaining to any previously installed hook).
void adtk_malloc_count_begin(void);

/// Restore the previous hook and return the allocations the `begin` thread made since `begin`.
uint64_t adtk_malloc_count_end(void);

#endif /* CADTESTKIT_MALLOC_H */
