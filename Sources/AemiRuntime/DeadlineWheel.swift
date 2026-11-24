//
//  DeadlineWheel.swift
//  AemiRuntime
//
//  ONE timer facility for the whole server, replacing three (`IdleDeadline` + `runIdleWatchdog`, the
//  per-operation `runLocalIdleWatchdog`, and `HTTP3StreamDeadlines`' own watchdog).
//
//  The defect it exists to fix: all three stored their target behind a `Mutex` and left a watchdog
//  parked in `clock.sleep(until:)`. Arming an EARLIER deadline therefore did not wake the sleeper, so
//  a fast 60 s body read followed by a 15 s keep-alive budget was enforced ~45 s late — the Slowloris
//  bound the operator configured (RFC 9112 §9.3; RFC 9114 §4.1 for HTTP/3; CWE-400) silently did not
//  hold. ``arm(_:until:)`` here wakes a parked watchdog whenever the wheel's minimum moves earlier.
//
//  Structure: an *indexed* binary min-heap keyed by the clock's instant. Each slot remembers where it
//  sits in the heap, so re-arming is an in-place key update plus a sift — O(log n), and allocation-free
//  once the heap and slot storage have reached their steady-state capacity, which matters because a
//  re-arm happens around EVERY read. The alternative (push a fresh entry, discard stale ones on pop)
//  would grow the heap with the number of re-arms rather than the number of live timers.
//
//  Not a hashed timing wheel: bucketing needs a fixed tick, and a bucket array sized for the spread
//  between a 1 s write budget and a 3600 s header budget is either coarse enough to lose the short end
//  or large enough to cost more than the heap it replaces. A heap needs no tick at all.
//
//  Keyed by a concrete `Duration` measured from the server's epoch rather than by the injected clock's
//  `Instant`. `Instant` is an associated type, so a wheel generic over it is *address-only* in the
//  unspecialized generic code the server actually compiles to (`AemiRuntime<C: Clock>` is instantiated
//  in the client module, so nothing specializes across the boundary): `Array.swapAt` on address-only
//  elements and every `Optional<Instant>` temporary then heap-allocate. Measured at 24 allocations per
//  re-arm — around every read, at 200k rps. Concrete `Duration` keys make it zero. ``AemiRuntime``
//  converts at the two edges it owns (see `deadlineKey(after:)`).
//
//  Standards: RFC 9112 §9.3, RFC 9114 §4.1/§8.1; CWE-400 (uncontrolled resource consumption),
//  CWE-416 in shape (the generation token on ``DeadlineHandle``).
//

internal import Synchronization

/// The armed deadlines of one connection, keyed by elapsed time since the server's epoch.
///
/// Thread-safe and, apart from the watchdog's own park, entirely synchronous: the serve loops arm and
/// disarm from their own tasks while the watchdog fires from its. Callbacks are invoked *outside* the
/// lock, so a lapse handler may freely re-enter ``arm(_:until:)`` or ``release(_:)``.
public final class DeadlineWheel: Sendable {
    /// One registered timer. `onLapse == nil` means the slot is free and awaiting reuse.
    private struct Slot {
        var generation: UInt32 = 0
        var onLapse: (@Sendable () -> DeadlineLapseAction)?
        /// Where this slot sits in ``State/heap``, or `-1` when disarmed.
        var heapIndex = -1
        /// Whether this timer has fired — the read loops' "did the read end on a deadline?" seam.
        var lapsed = false
    }

    /// One armed timer's heap entry.
    ///
    /// The target lives here rather than in the slot so the ordering never has to compare `Optional`s.
    private struct Entry {
        var slot: Int32
        var target: Duration
    }

    private struct State {
        var slots: [Slot] = []
        var freeSlots: [Int32] = []
        var heap: [Entry] = []
        /// The single parked watchdog, resumed when the wheel's minimum moves earlier.
        var waiter: UnsafeContinuation<Void, Never>?

        /// The slot `handle` still owns, or `nil` if it was released (or never registered).
        ///
        /// A method rather than a free function taking `State`: passing the struct by value retains
        /// `slots`/`heap`, and the very next in-place heap mutation would then see a non-unique buffer
        /// and copy it — an allocation on the path that runs around every read.
        func liveIndex(of handle: DeadlineHandle) -> Int? {
            let index = Int(handle.slot)
            guard index >= 0, index < slots.count,
                slots[index].generation == handle.generation, slots[index].onLapse != nil
            else {
                return nil
            }
            return index
        }

        /// Whether something is armed strictly earlier than `bound` (or armed at all, when nil).
        func hasArm(earlierThan bound: Duration?) -> Bool {
            guard let earliest = heap.first?.target else {
                return false
            }
            return bound.map { earliest < $0 } ?? true
        }
    }

    private let state = Mutex(State())

    public init() {}

    deinit {
        // No teardown beyond ARC: a wheel is only released once its watchdog task is gone, and a
        // parked watchdog holds a reference, so there is never a live waiter here.
    }

    /// The earliest armed instant, or `nil` when nothing is armed.
    public var earliest: Duration? { state.withLock { $0.heap.first?.target } }

    /// Whether no timer is armed — every one has been disarmed, fired, or released.
    public var isEmpty: Bool { state.withLock(\.heap.isEmpty) }

    // MARK: - Registration

    /// Registers a timer, returning the handle every later operation must present.
    ///
    /// `onLapse` runs on the watchdog's task, outside this wheel's lock, and must not block: it either
    /// flags state the serve loop reads or yields into a mailbox. Its return value decides whether the
    /// watchdog keeps serving this wheel's other timers.
    public func register(_ onLapse: @escaping @Sendable () -> DeadlineLapseAction) -> DeadlineHandle {
        state.withLock { s in
            guard let recycled = s.freeSlots.popLast() else {
                s.slots.append(Slot(onLapse: onLapse))
                return DeadlineHandle(slot: Int32(s.slots.count - 1), generation: 0)
            }
            let index = Int(recycled)
            s.slots[index].onLapse = onLapse
            s.slots[index].heapIndex = -1
            s.slots[index].lapsed = false
            return DeadlineHandle(slot: recycled, generation: s.slots[index].generation)
        }
    }

    /// Retires `handle` and recycles its slot, so nothing armed for it can still fire.
    ///
    /// The generation bump is what makes this final: the released handle no longer matches the slot,
    /// so a late `arm`/`disarm` carrying it — a teardown racing an in-flight read — is a no-op rather
    /// than a timer running against whichever connection next occupies the slot.
    public func release(_ handle: DeadlineHandle) {
        state.withLock { s in
            guard let index = s.liveIndex(of: handle) else {
                return
            }
            remove(at: s.slots[index].heapIndex, in: &s)
            s.slots[index].onLapse = nil
            s.slots[index].generation &+= 1
            s.freeSlots.append(handle.slot)
        }
    }

    // MARK: - Arming

    /// Arms `handle` to lapse at `instant`, waking a watchdog already parked on a later target.
    ///
    /// The hot path — this runs around every read. An already-armed handle is repositioned in place,
    /// so nothing is allocated once the heap has reached its steady-state capacity.
    public func arm(_ handle: DeadlineHandle, until key: Duration) {
        let waiter = state.withLock { s -> UnsafeContinuation<Void, Never>? in
            guard let index = s.liveIndex(of: handle) else {
                return nil
            }
            let before = s.heap.first?.target
            let position = s.slots[index].heapIndex
            if position >= 0 {
                s.heap[position].target = key
                Self.reposition(position, in: &s)
            } else {
                s.heap.append(Entry(slot: handle.slot, target: key))
                Self.siftUp(s.heap.count - 1, in: &s)
            }
            return Self.waiterToWake(movedEarlierThan: before, in: &s)
        }
        waiter?.resume()
    }

    /// Disarms `handle` after its read returned, so the processing between reads is not timed.
    ///
    /// Never wakes the watchdog: removing a timer can only push the wheel's minimum later, and a
    /// watchdog that wakes on a target nothing is armed for simply re-parks.
    public func disarm(_ handle: DeadlineHandle) {
        state.withLock { s in
            guard let index = s.liveIndex(of: handle) else {
                return
            }
            remove(at: s.slots[index].heapIndex, in: &s)
        }
    }

    /// Whether the timer registered for `handle` has fired.
    ///
    /// How a read loop tells a deadline lapse from a peer EOF.
    public func hasLapsed(_ handle: DeadlineHandle) -> Bool {
        state.withLock { s in s.liveIndex(of: handle).map { s.slots[$0].lapsed } ?? false }
    }

    // MARK: - Firing

    /// Fires every timer due at `now`, reporting what the lapses ask the watchdog to do.
    ///
    /// Callbacks run outside the lock, so one may re-arm or release freely. Each due timer is removed
    /// before its callback runs, so it lapses exactly once.
    public func fireLapsed(at now: Duration) -> DeadlineFiring {
        let due = state.withLock { s -> [@Sendable () -> DeadlineLapseAction] in
            var callbacks: [@Sendable () -> DeadlineLapseAction] = []
            while let head = s.heap.first, head.target <= now {
                let index = Int(head.slot)
                remove(at: 0, in: &s)
                s.slots[index].lapsed = true
                if let onLapse = s.slots[index].onLapse {
                    callbacks.append(onLapse)
                }
            }
            return callbacks
        }
        guard !due.isEmpty else {
            return DeadlineFiring(isEmpty: true, action: .keepWatching)
        }
        let stop = due.map { $0() }.contains(.stopWatching)
        return DeadlineFiring(isEmpty: false, action: stop ? .stopWatching : .keepWatching)
    }

    /// Suspends until a deadline earlier than `bound` is armed, or the task is cancelled.
    ///
    /// Passing `nil` means "until anything is armed", which is what lets an idle connection park with
    /// *no* wakeups at all — the three watchdogs this replaced each polled at
    /// `min(headerReadTimeout, idleTimeout, keepAliveTimeout)` while nothing was armed, purely because
    /// they had no way to be told.
    public func waitForArm(earlierThan bound: Duration?) async {
        await withTaskCancellationHandler {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if Task.isCancelled || s.hasArm(earlierThan: bound) {
                        return true
                    }
                    s.waiter = continuation
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        } onCancel: {
            takeWaiter()?.resume()
        }
    }

    // MARK: - Slot lookup

    /// Detaches the parked watchdog, if any, so exactly one caller can resume it.
    private func takeWaiter() -> UnsafeContinuation<Void, Never>? {
        state.withLock { s in
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
    }

    /// The parked watchdog to resume when the wheel's minimum has moved earlier than `before`.
    private static func waiterToWake(
        movedEarlierThan before: Duration?,
        in s: inout State
    ) -> UnsafeContinuation<Void, Never>? {
        guard s.hasArm(earlierThan: before) else {
            return nil
        }
        let waiter = s.waiter
        s.waiter = nil
        return waiter
    }

    // MARK: - Indexed binary min-heap

    /// Removes the entry at `position`, keeping the array's capacity for the next arm.
    private func remove(at position: Int, in s: inout State) {
        guard position >= 0, position < s.heap.count else {
            return
        }
        s.slots[Int(s.heap[position].slot)].heapIndex = -1
        let last = s.heap.count - 1
        guard position != last else {
            s.heap.removeLast()
            return
        }
        s.heap[position] = s.heap[last]
        s.heap.removeLast()
        s.slots[Int(s.heap[position].slot)].heapIndex = position
        Self.reposition(position, in: &s)
    }

    /// Restores the heap around an entry whose key changed in either direction.
    private static func reposition(_ position: Int, in s: inout State) {
        guard position >= 0, position < s.heap.count else {
            return
        }
        let slot = Int(s.heap[position].slot)
        siftUp(position, in: &s)
        if s.slots[slot].heapIndex == position {
            siftDown(position, in: &s)
        }
    }

    private static func siftUp(_ start: Int, in s: inout State) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard s.heap[index].target < s.heap[parent].target else {
                break
            }
            s.heap.swapAt(index, parent)
            s.slots[Int(s.heap[index].slot)].heapIndex = index
            index = parent
        }
        s.slots[Int(s.heap[index].slot)].heapIndex = index
    }

    private static func siftDown(_ start: Int, in s: inout State) {
        var index = start
        while true {
            let left = 2 * index + 1
            guard left < s.heap.count else {
                break
            }
            let right = left + 1
            var best = left
            if right < s.heap.count, s.heap[right].target < s.heap[left].target {
                best = right
            }
            guard s.heap[best].target < s.heap[index].target else {
                break
            }
            s.heap.swapAt(index, best)
            s.slots[Int(s.heap[index].slot)].heapIndex = index
            index = best
        }
        s.slots[Int(s.heap[index].slot)].heapIndex = index
    }
}
