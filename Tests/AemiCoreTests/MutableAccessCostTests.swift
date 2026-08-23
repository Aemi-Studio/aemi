import Foundation
import Observation
import Synchronization
import Testing
import AemiCore

/// Guards the per-instance key-path hoist in ``Mutable``.
///
/// Key paths rooted in a *generic* type are instantiated by the runtime on
/// every use, and each instantiation allocates. Letting the `@Observable`
/// macro synthesise `wrappedValue` therefore cost ~531 ns and 2 allocations
/// per read, against ~10 ns for the same shape on a concrete class. Hoisting
/// the key path to a stored `let` removes the gap entirely.
///
/// If someone reverts `Mutable.wrappedValue` to a plain macro-synthesised
/// stored property, this test fails.
/// Non-generic control with the same observable shape.
///
/// File scope, not nested: `@Observable` emits `extension <Type>: Observable`
/// at file scope, which cannot name a `private` nested type.
@Observable
final class ConcreteBuffer {
    var value: Int
    init(value: Int) { self.value = value }
}

private struct Model: Equatable {
    var value: Int
}

@Suite("Mutable access cost")
struct MutableAccessCostTests {

    @Test
    func genericReadIsNotSlowerThanConcreteRead() {
        let iterations = 200_000
        let generic = Mutable(Model(value: 1))
        let concrete = ConcreteBuffer(value: 1)
        let clock = ContinuousClock()

        // Warm both paths so first-touch metadata work is not attributed to
        // either measurement.
        var warm = 0
        for _ in 0..<10_000 { warm &+= generic.value &+ concrete.value }
        #expect(warm == 20_000)

        func best(_ body: () -> Int) -> Double {
            var fastest = Double.infinity
            for _ in 0..<5 {
                var sink = 0
                let elapsed = clock.measure {
                    for _ in 0..<iterations { sink &+= body() }
                }
                #expect(sink == iterations)
                let total = Double(elapsed.components.seconds) * 1e9
                    + Double(elapsed.components.attoseconds) / 1e9
                fastest = min(fastest, total / Double(iterations))
            }
            return fastest
        }

        let genericNS = best { generic.value }
        let concreteNS = best { concrete.value }

        print("""
        [mutable-access] generic Mutable<Model>.wrappedValue: \(genericNS.formatted(.number.precision(.fractionLength(1)))) ns/read
        [mutable-access] concrete @Observable control:        \(concreteNS.formatted(.number.precision(.fractionLength(1)))) ns/read
        """)

        // Without the hoist the generic path is ~50x the concrete one; with it
        // this runs ~2.8x in a debug build (~1x optimised). An 8x ceiling
        // catches the regression with wide margin for a loaded CI machine.
        #expect(
            genericNS < concreteNS * 8,
            """
            Generic Mutable read cost regressed: \(genericNS) ns vs \
            \(concreteNS) ns for the concrete control. Check that \
            Mutable.wrappedValue still routes through the stored \
            wrappedValueKeyPath instead of a synthesised \\.wrappedValue.
            """
        )
    }

    /// The hoist must not change observation semantics: mutations still
    /// notify, and `_modify` still yields in place.
    @Test
    func mutationsStillNotifyObservers() {
        let buffer = Mutable(Model(value: 1))
        // `onChange` is @Sendable, so the flag cannot be a captured `var`.
        let fired = Atomic<Bool>(false)
        withObservationTracking {
            _ = buffer.wrappedValue
        } onChange: {
            fired.store(true, ordering: .relaxed)
        }
        buffer.value = 2
        // Hoisted: `Atomic` is ~Copyable and #expect requires Copyable.
        let didFire = fired.load(ordering: .relaxed)
        #expect(didFire)
        #expect(buffer.wrappedValue.value == 2)
    }

    @Test
    func revertRestoresTheOriginal() {
        let buffer = Mutable(Model(value: 1))
        buffer.value = 99
        #expect(buffer.hasChanges)
        buffer.revert()
        #expect(!buffer.hasChanges)
        #expect(buffer.wrappedValue.value == 1)
    }
}
