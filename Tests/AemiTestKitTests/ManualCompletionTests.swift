import Synchronization
import Testing

@testable import AemiTestKit

@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct ManualCompletionTests {
    private struct Failure: Error, Equatable {}

    @Test
    func `requests are numbered from zero and complete in any order`() async throws {
        let completion = ManualCompletion<String>()
        let first = Task { try await completion.receive() }
        try await completion.requests.wait(forAtLeast: 1)
        let second = Task { try await completion.receive() }
        try await completion.requests.wait(forAtLeast: 2)
        #expect(completion.pendingCount == 2)

        try completion.complete(at: 1, returning: "newer")
        #expect(try await second.value == "newer")
        #expect(completion.pendingCount == 1)

        try completion.complete(at: 0, returning: "older")
        #expect(try await first.value == "older")
        #expect(completion.pendingCount == 0)
    }

    @Test
    func `a request can be failed`() async throws {
        let completion = ManualCompletion<Int>()
        let request = Task { try await completion.receive() }
        try await completion.requests.wait(forAtLeast: 1)

        try completion.complete(at: 0, throwing: Failure())

        await #expect(throws: Failure.self) { try await request.value }
    }

    @Test
    func `completing an unknown or finished request throws`() async throws {
        let completion = ManualCompletion<Int>()
        let request = Task { try await completion.receive() }
        try await completion.requests.wait(forAtLeast: 1)

        #expect(throws: ManualCompletion<Int>.CompletionError.requestNotFound(reason: .indexNotFound)) {
            try completion.complete(at: 1, returning: 0)
        }
        #expect(throws: ManualCompletion<Int>.CompletionError.requestNotFound(reason: .indexNotFound)) {
            try completion.complete(at: -1, returning: 0)
        }

        try completion.complete(at: 0, returning: 7)
        #expect(try await request.value == 7)
        #expect(throws: ManualCompletion<Int>.CompletionError.requestNotFound(reason: .alreadyCompleted)) {
            try completion.complete(at: 0, returning: 8)
        }
    }

    @Test
    func `cancelling the caller leaves the request pending until it is completed`() async throws {
        let completion = ManualCompletion<Int>()
        let request = Task { try await completion.receive() }
        try await completion.requests.wait(forAtLeast: 1)

        request.cancel()
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(completion.pendingCount == 1, "a cancelled service may still return a result")

        try completion.complete(at: 0, returning: 5)
        #expect(try await request.value == 5)
    }

    @Test
    func `concurrent requests can be completed from synchronous closures`() async throws {
        let completion = ManualCompletion<Int>()
        let count = 20
        let responses = Task {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0 ..< count { group.addTask { try await completion.receive() } }
                return try await group.reduce(into: []) { $0.append($1) }
            }
        }
        try await completion.requests.wait(forAtLeast: count)

        // Completion is callable synchronously even when the requests run on other tasks.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< count {
                let complete: @Sendable () throws -> Void = { try completion.complete(at: index, returning: index) }
                group.addTask { try complete() }
            }
            try await group.waitForAll()
        }

        #expect(try await responses.value.sorted() == Array(0 ..< count))
    }
}
