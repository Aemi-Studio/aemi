#if canImport(ObjectiveC)
    import AemiTestKit
    import Foundation
    import Testing

    @Suite("KeyValueProbe") struct KeyValueProbeTests {
        @Test func `sees the value it starts with and each change, made on another thread`() async throws {
            let object = KeyValueObserved()
            let probe = KeyValueProbe(object, \.number)
            try await probe.wait(until: { $0 == 0 })
            Thread.detachNewThread {
                for value in 1 ... 5 { object.number = value }
            }
            try await probe.wait(until: { $0 == 5 })
            #expect(probe.values.events == [0, 1, 2, 3, 4, 5])
            try await probe.wait(history: { $0.contains(2) && $0.last == 5 })
        }

        @Test func `times out naming the object and the key path`() async throws {
            let probe = KeyValueProbe(KeyValueObserved(), \.number)
            let error = try #require(
                await #expect(throws: AsyncEventProbeTimeoutError.self) {
                    try await probe.wait(until: { $0 == 6 }, timeout: .milliseconds(20))
                }
            )
            #expect(error.label.contains("KeyValueObserved") && error.recentEvents == ["0"])
        }

        @Test func `stops observing when it is gone`() async throws {
            let object = KeyValueObserved()
            var probe: KeyValueProbe<KeyValueObserved, Int>? = KeyValueProbe(object, \.number)
            let values = try #require(probe?.values)
            probe = nil
            object.number = 1
            #expect(values.events == [0])
        }
    }
#endif
