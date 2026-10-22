import Testing

@testable import AemiTestKit

#if canImport(ObjectiveC)
    struct DeallocationProbeTests {
        private final class Object {}

        @Test
        func `records once the object is deallocated`() throws {
            var object: Object? = Object()
            let probe = deallocationProbe(of: try #require(object))

            #expect(probe.isEmpty)
            object = nil

            #expect(probe.count == 1)
        }

        @Test
        func `does not retain the object`() throws {
            var object: Object? = Object()
            weak let weakObject = object
            _ = deallocationProbe(of: try #require(object))

            object = nil

            #expect(weakObject == nil)
        }

        @Test
        func `several probes can watch the same object`() throws {
            var object: Object? = Object()
            let first = deallocationProbe(of: try #require(object))
            let second = deallocationProbe(of: try #require(object))

            object = nil

            #expect(first.count == 1)
            #expect(second.count == 1)
        }

        @Test
        func `a deallocation on another thread wakes a waiting test`() async throws {
            // The object lives and dies inside a detached task, so the last reference goes on another thread.
            let probe = await Task.detached { deallocationProbe(of: Object()) }.value

            try await probe.wait(forAtLeast: 1)
        }

        @Test
        func `the probe is named for the watched type unless given a label`() async throws {
            let object = Object()
            let probe = deallocationProbe(of: object)
            let named = deallocationProbe(of: object, label: "the session")
            let error = try await timeout(of: probe)
            let namedError = try await timeout(of: named)

            #expect(error.label.contains("Object"))
            #expect(namedError.label == "the session")
        }

        private func timeout<Event: Sendable>(of probe: AsyncEventProbe<Event>) async throws
            -> AsyncEventProbeTimeoutError
        {
            do {
                try await probe.wait(forAtLeast: 1, timeout: .milliseconds(20))
            } catch let error as AsyncEventProbeTimeoutError {
                return error
            }
            Issue.record("the wait did not time out")
            throw CancellationError()
        }
    }
#endif
