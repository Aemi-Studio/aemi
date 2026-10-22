#if canImport(ObjectiveC)
    import ObjectiveC

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
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public func deallocationProbe(
        of object: AnyObject,
        label: String? = nil,
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line
    ) -> CountProbe<Never> {
        let probe = CountProbe(
            label: label ?? "deallocation of \(type(of: object))", file: file, function: function, line: line)
        let recorder = DeallocationRecorder(probe: probe)
        // The recorder's own address is a key unique to this probe, so several probes can watch one object.
        unsafe objc_setAssociatedObject(
            object,
            unsafe Unmanaged.passUnretained(recorder).toOpaque(),
            recorder,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return probe
    }

    /// Lives as long as the watched object and records on the probe when it is released with it.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    private final class DeallocationRecorder: Sendable {
        private let probe: CountProbe<Never>

        init(probe: CountProbe<Never>) {
            self.probe = probe
        }

        deinit {
            probe.record()
        }
    }
#endif
