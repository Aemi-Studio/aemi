import AemiCore
import Testing

@testable import AemiTesting

/// Load-bearing isolation coverage for the `TaskProvider` closure attributes, exercised through
/// the existential (`any TaskProvider`) exactly as production call sites hold the provider.
///
/// `task`'s `operation` carries `@_inheritActorContext` / `@_implicitSelfCapture`;
/// `detachedTask`'s deliberately carries neither. These tests pin that the attributes survive
/// existential dispatch — for the full protocol requirements and for the defaulted convenience
/// overloads — with `DefaultTaskProvider` and `TaskProviderSpy` alike.
@Suite("TaskProvider isolation")
struct TaskProviderIsolationTests {

    /// Fresh instances per test function so spy bookkeeping never crosses tests.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    private static func providers() -> [any TaskProvider] {
        [DefaultTaskProvider(), TaskProviderSpy()]
    }

    // MARK: - (a) Closure literals inherit the caller's actor context

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    @MainActor
    func requirementClosureLiteralInheritsMainActorIsolation(
        provider: any TaskProvider
    ) async throws {
        let probe = AsyncProbe<Bool>()
        provider.task(role: .work, priority: nil) {
            probe.send(#isolation === MainActor.shared)
        }
        let ranOnMain = try await probe.next()
        #expect(ranOnMain == true)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    @MainActor
    func convenienceClosureLiteralInheritsMainActorIsolation(
        provider: any TaskProvider
    ) async throws {
        let probe = AsyncProbe<Bool>()
        provider.task {
            probe.send(#isolation === MainActor.shared)
        }
        let ranOnMain = try await probe.next()
        #expect(ranOnMain == true)
    }

    // MARK: - (b) Self-capturing closures from a @MainActor type stay main-isolated

    @MainActor
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    private final class MainActorHost {
        let probe = AsyncProbe<Bool>()
        private(set) var mutatedMainActorState = false

        func spawn(through provider: any TaskProvider) {
            provider.task {
                // Unqualified `mutatedMainActorState` / `probe` compile only if
                // `@_implicitSelfCapture` holds through the existential, and the write to
                // main-actor state only type-checks (and runs safely) if the closure
                // inherited `@MainActor` via `@_inheritActorContext`.
                mutatedMainActorState = true
                probe.send(#isolation === MainActor.shared)
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    @MainActor
    func selfCapturingClosureFromMainActorTypeRunsOnMain(
        provider: any TaskProvider
    ) async throws {
        let host = MainActorHost()
        host.spawn(through: provider)
        let ranOnMain = try await host.probe.next()
        #expect(ranOnMain == true)
        #expect(host.mutatedMainActorState)
    }

    // MARK: - (c) Detached bodies run off the main actor

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    @MainActor
    func detachedRequirementClosureRunsOffTheMainActor(
        provider: any TaskProvider
    ) async throws {
        let probe = AsyncProbe<Bool>()
        provider.detachedTask(role: .work, priority: nil) {
            probe.send(#isolation === MainActor.shared)
        }
        let ranOnMain = try await probe.next()
        #expect(ranOnMain == false)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    @MainActor
    func detachedConvenienceClosureRunsOffTheMainActor(
        provider: any TaskProvider
    ) async throws {
        let probe = AsyncProbe<Bool>()
        provider.detachedTask {
            probe.send(#isolation === MainActor.shared)
        }
        let ranOnMain = try await probe.next()
        #expect(ranOnMain == false)
    }

    // MARK: - (d) Priorities forward

    // Both priority tests spawn from inside a `.utility` wrapper task so the spy's completion
    // monitor — which inherits the spawning context's priority and awaits the spawned task's
    // result — cannot escalate the task under test above the priority being asserted.

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    func taskForwardsExplicitPriority(provider: any TaskProvider) async throws {
        let probe = AsyncProbe<TaskPriority>()
        Task(priority: .utility) {
            provider.task(role: .work, priority: .utility) {
                probe.send(Task.currentPriority)
            }
        }
        let priority = try await probe.next()
        #expect(priority == .utility)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test(arguments: providers())
    func detachedTaskForwardsExplicitPriority(provider: any TaskProvider) async throws {
        let probe = AsyncProbe<TaskPriority>()
        Task(priority: .utility) {
            provider.detachedTask(role: .work, priority: .utility) {
                probe.send(Task.currentPriority)
            }
        }
        let priority = try await probe.next()
        #expect(priority == .utility)
    }

    // MARK: - Sugar

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func defaultSugarProducesTheProductionProvider() {
        let provider: any TaskProvider = .default
        #expect(provider is DefaultTaskProvider)
    }
}
