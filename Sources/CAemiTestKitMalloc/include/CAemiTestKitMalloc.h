#ifndef CADTESTKIT_MALLOC_H
#define CADTESTKIT_MALLOC_H

#include <stdint.h>

/// Process-wide heap-allocation counting for test perf guards (e.g. AemiTestKit's `expectAllocations`).
///
/// On Darwin this installs libmalloc's logging hook (`malloc_logger`) — a documented-in-practice
/// tooling seam Instruments uses. It is enabled only in TEST / tooling builds and never ships in an
/// App-Store binary, so the private symbol is acceptable here. On other platforms the counter is a
/// no-op and `adtk_malloc_counting_available()` returns 0, so the Swift oracle degrades gracefully.
///
/// Measured on 2026-10-18, and NOT process-wide despite what this once claimed. A thread that had
/// already allocated before `begin` installed the hook is invisible: with the hook installed by the
/// main thread and a worker provably making 1,006 allocations inside the window, the count was 0.
/// The same worker counting its own allocations sees them exactly. libmalloc appears to resolve the
/// logger pointer per thread at first use, so an already-warm thread keeps the old one.
///
/// Consequences, which matter more than the detail:
///   * A count is trustworthy only for allocations on the thread that opened the window.
///   * Over code running on a warm thread pool it UNDER-REPORTS, and an assertion can pass while the
///     code allocates. In a Swift 6 package with strict concurrency that is most real code.
///   * Do not state a process-wide guarantee from this API.
///
/// On a single thread it is exact: 1,000 mallocs count 1,000, 10,000 count 10,000, and a body that
/// allocates nothing counts 0. Measurements must not overlap — AemiTestKit's `mallocDelta`
/// serializes them. A `begin` while the hook is already installed is ignored rather than chaining
/// the hook to itself.

/// 1 when allocation counting is available on this platform (Darwin), 0 otherwise.
int adtk_malloc_counting_available(void);

/// Reset the counter and install the counting hook (chaining to any previously installed hook).
void adtk_malloc_count_begin(void);

/// Restore the previous hook and return the number of allocations observed since `begin`.
uint64_t adtk_malloc_count_end(void);

#endif /* CADTESTKIT_MALLOC_H */
