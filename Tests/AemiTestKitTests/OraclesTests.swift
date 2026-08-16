import Testing

@testable import AemiTestKit

/// A typed error with a payload, standing in for the AD-family's `DBError` /
/// `JSONPathError` so the discipline asserts can be exercised.
private enum SampleError: Error, Equatable {
    case syntax(String)
    case runtime(code: Int)
}

@Suite(.tags(.parity))
struct OraclesTests {
    // MARK: - expectThrows(_:where:)

    @Test
    func `accepts the right type with a matching payload`() {
        let caught = expectThrows(
            {
                throw SampleError.syntax("nested too deeply")
            },
            where: { (error: SampleError) in
                if case .syntax(let message) = error { return message.contains("deeply") }
                return false
            })
        #expect(caught == .syntax("nested too deeply"))
    }

    @Test
    func `rejects a wrong payload (records an issue)`() {
        withKnownIssue {
            expectThrows(
                {
                    throw SampleError.runtime(code: 7)
                },
                where: { (error: SampleError) in
                    // Demand a syntax error; the runtime error must be rejected.
                    if case .syntax = error { return true }
                    return false
                })
        }
    }

    @Test
    func `rejects the wrong error type (records an issue)`() {
        struct OtherError: Error {}
        withKnownIssue {
            expectThrows(
                {
                    throw OtherError()
                }, where: { (_: SampleError) in true })
        }
    }

    @Test
    func `rejects a non-throwing expression (records an issue)`() {
        withKnownIssue {
            expectThrows(
                {
                    42
                }, where: { (_: SampleError) in true })
        }
    }

    @Test
    func `async form catches a matching typed error`() async {
        let caught = await expectThrows(
            {
                try await Task.sleep(for: .nanoseconds(1))
                throw SampleError.runtime(code: 9)
            },
            where: { (error: SampleError) in
                if case .runtime(let code) = error { return code == 9 }
                return false
            })
        #expect(caught == .runtime(code: 9))
    }

    // MARK: - ReferenceComparison

    @Test
    func `multiset row comparison ignores order`() {
        let ours = [[1, 2], [3, 4], [5, 6]]
        let theirs = [[5, 6], [1, 2], [3, 4]]
        // Dogfood the kit's typed asserts: passing the Bool result lets `rowsMatch`
        // type-check on its own (fast) instead of inside the `#expect` macro's combined
        // constraint system — the exact >100ms type-check the strict CI lane rejects.
        expectTrue(
            ReferenceComparison.rowsMatch(
                ours, theirs, ordered: false, elementOrder: { $0 - $1 }))
        // Ordered comparison sees the difference.
        expectFalse(
            ReferenceComparison.rowsMatch(
                ours, theirs, ordered: true, elementOrder: { $0 - $1 }))
    }

    @Test
    func `NaN-aware float match treats NaN == NaN`() {
        #expect(ReferenceComparison.floatMatches(Double.nan, .nan))
        #expect(ReferenceComparison.floatMatches(1.5, 1.5))
        #expect(!ReferenceComparison.floatMatches(1.5, 2.5))
    }

    // MARK: - Round-trip & parity

    @Test
    func `round-trip identity passes for a faithful codec`() {
        expectRoundTripIdentity([1, 2, 3]) { value in value.reversed().reversed() }
    }

    @Test
    func `round-trip identity records a mismatch`() {
        withKnownIssue {
            expectRoundTripIdentity([1, 2, 3]) { value in value.reversed() }
        }
    }

    @Test
    func `parity passes for equal values and records on divergence`() {
        expectParity(10, 10)
        withKnownIssue { expectParity(10, 11) }
    }

    @Test
    func `row-set parity oracle ignores order and records a divergent multiset`() {
        let ours = [[1, 2], [3, 4]]
        expectParity(rows: ours, [[3, 4], [1, 2]], ordered: false, elementOrder: { $0 - $1 })
        withKnownIssue {
            expectParity(rows: ours, [[1, 2], [9, 9]], ordered: false, elementOrder: { $0 - $1 })
        }
    }
}
