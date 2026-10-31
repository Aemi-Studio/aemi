#if canImport(ObjectiveC)
    // `public import`: the probe's creation site is Swift Testing's `SourceLocation`. Inside the condition, since
    // nothing else in the file is public and an unused public import is an error.
    internal import ObjectiveC
    public import Testing

    /// Returns a count-only probe that records once `object` is deallocated, without retaining it.
    ///
    /// Use it for objects released asynchronously by their owner, such as a `URLSession` after its
    /// invalidation, so a test waits for the deallocation instead of yielding until it presumably
    /// happened:
    ///
    /// ```swift
    /// var session: URLSession? = makeSession()
    /// let released = deallocationProbe(of: session!)
    /// session = nil
    /// try await released.wait(forAtLeast: 1)
    /// ```
    ///
    /// Several probes can watch one object. The probe records when the *object* is released, on whichever
    /// thread drops the last reference, so a test that needs to see the deallocation synchronously must drop
    /// the reference on its own thread.
    ///
    /// Available where the Objective-C runtime is (Apple platforms): it hangs the recorder on the object as an
    /// associated object, which dies with it.
    public func deallocationProbe(
        of object: AnyObject,
        label: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> AsyncEventProbe<Never> {
        let probe = AsyncEventProbe(
            label: label ?? "deallocation of \(type(of: object))", sourceLocation: sourceLocation)
        let recorder = DeallocationRecorder(probe: probe)
        // The recorder's own address is a key unique to this probe, so several probes can watch one object.
        objc_setAssociatedObject(
            object,
            Unmanaged.passUnretained(recorder).toOpaque(),
            recorder,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return probe
    }

    /// Lives as long as the watched object and records on the probe when it is released with it.
    private final class DeallocationRecorder: Sendable {
        private let probe: AsyncEventProbe<Never>

        init(probe: AsyncEventProbe<Never>) {
            self.probe = probe
        }

        deinit {
            probe.record()
        }
    }
#endif
