import AemiMetrics
import Testing

struct ProcessProbeTests {
    @Test func snapshotPopulatesLiveCounters() {
        let s = ProcessProbe.snapshot()
        #expect(s.residentBytes > 0)
        #expect(s.footprintBytes > 0)
        #expect(s.wallNanos > 0)
    }

    @Test func peakResidentIsReadable() {
        #expect(ProcessProbe.peakResidentBytes() > 0)
    }

    @Test func monotonicClockDoesNotGoBackwards() {
        let a = ProcessProbe.monotonicNanos()
        let b = ProcessProbe.monotonicNanos()
        #expect(b >= a)
    }

    // A non-trivial compute loop must register elapsed wall time and consumed CPU. The result is
    // returned and asserted so the optimizer can't elide the work.
    @Test func measureCapturesCostAndReturnsResult() {
        let (delta, result) = ProcessProbe.measure { () -> Int in
            var sum = 0
            for i in 0 ..< 20_000_000 { sum &+= i & 0xFF }
            return sum
        }
        #expect(result != 0)
        #expect(delta.wallNanos > 0)
        #expect(delta.processCPUNanos > 0)
    }

    @Test func deltaOfIdenticalSnapshotIsZeroTime() {
        let s = ProcessProbe.snapshot()
        let d = ProcessProbe.delta(from: s, to: s)
        #expect(d.wallNanos == 0)
        #expect(d.processCPUNanos == 0)
        #expect(d.residentBytesDelta == 0)
    }

    #if arch(arm64) && canImport(Darwin)
        // Apple Silicon reports retired instructions through proc_pid_rusage; a real workload moves it.
        @Test func instructionsCountedOnAppleSilicon() {
            let (delta, result) = ProcessProbe.measure { () -> Int in
                var sum = 0
                for i in 0 ..< 20_000_000 { sum &+= i & 0x7 }
                return sum
            }
            #expect(result != 0)
            // VIRTUALIZED arm64 (hosted CI runners) exposes no PMU: `proc_pid_rusage` then reports
            // 0 retired instructions — the API's documented "unavailable" signal. The absolute
            // counter after any workload is definitively positive wherever the PMU exists, so gate
            // the strict assertion on it; real hardware keeps the full check.
            guard ProcessProbe.snapshot().instructions > 0 else { return }
            #expect(delta.instructions > 0)
        }
    #endif
}
