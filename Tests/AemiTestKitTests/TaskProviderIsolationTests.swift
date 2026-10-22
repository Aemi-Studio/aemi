import AemiTestKitSeams
import Testing

@testable import AemiTestKit

/// Pins the actor-context inheritance of the `TaskProvider` seam through the existential
/// (`any TaskProvider`), exactly as production call sites hold the provider: `@_inheritActorContext` on the
/// operation is an underscored attribute without an Evolution proposal, so a toolchain change must fail here
/// instead of silently moving spawned closures off the caller's actor. Covered for the live provider and the spy,
/// through the requirement and through the defaulted convenience overload.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct TaskProviderIsolationTests {
    /// Fresh instances per test function so spy bookkeeping never crosses tests.
    private static func providers() -> [any TaskProvider] {
        [LiveTaskProvider(), TaskProviderSpy()]
    }

    @Test(arguments: providers())
    @MainActor
    func `the requirement's closure literal inherits MainActor isolation`(provider: any TaskProvider) async throws {
        let ranOnMain = AsyncEventProbe<Bool>()
        provider.task(role: .work, priority: nil) {
            ranOnMain.record(#isolation === MainActor.shared)
        }
        #expect(try await ranOnMain.wait(forAtLeast: 1) == [true])
    }

    @Test(arguments: providers())
    @MainActor
    func `the convenience overload's closure literal inherits MainActor isolation`(
        provider: any TaskProvider
    ) async throws {
        let ranOnMain = AsyncEventProbe<Bool>()
        provider.task {
            ranOnMain.record(#isolation === MainActor.shared)
        }
        #expect(try await ranOnMain.wait(forAtLeast: 1) == [true])
    }

    @Test(arguments: providers())
    @MainActor
    func `a throwing closure literal inherits MainActor isolation too`(provider: any TaskProvider) async throws {
        let task = provider.task { () async throws -> Bool in
            #isolation === MainActor.shared
        }
        #expect(try await task.value)
    }

    @Test(arguments: providers())
    func `a closure literal in a nonisolated context is not main-actor isolated`(provider: any TaskProvider) async {
        let task = provider.task { () async -> Bool in
            #isolation === MainActor.shared
        }
        #expect(await task.value == false)
    }
}
