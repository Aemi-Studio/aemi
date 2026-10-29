#if canImport(Darwin)
    import Darwin

    /// A detached thread with a stack of the size asked for, made with `pthread_create`: no Foundation, and a 64 KiB
    /// stack for a thread that only waits in `kevent` costs nothing measurable at idle, where Foundation's `Thread`
    /// raised a process's idle memory by about 120 KiB (measured in ask, ADR-0016 there).
    enum DetachedThread {
        /// Runs `work` on a new detached thread with `stackBytes` of stack.
        /// - Returns: false when the system refused the thread; `work` then never runs.
        @discardableResult
        static func start(stackBytes: Int, _ work: @escaping @Sendable () -> Void) -> Bool {
            var attributes = pthread_attr_t()
            unsafe pthread_attr_init(&attributes)
            unsafe pthread_attr_setstacksize(&attributes, stackBytes)
            unsafe pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED)
            defer { unsafe pthread_attr_destroy(&attributes) }
            let box = unsafe Unmanaged.passRetained(Box(work))
            var thread: pthread_t?
            let status = unsafe pthread_create(
                &thread, &attributes,
                { raw in
                    let box = unsafe Unmanaged<Box>.fromOpaque(raw).takeRetainedValue()
                    box.work()
                    return nil
                }, unsafe box.toOpaque())
            if status != 0 { unsafe box.release() }
            return status == 0
        }

        /// Carries the closure through the C entry point.
        private final class Box: Sendable {
            let work: @Sendable () -> Void
            init(_ work: @escaping @Sendable () -> Void) { self.work = work }
        }
    }
#endif
