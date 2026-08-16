import Testing

@testable import AemiTestKit

struct FixturesTests {
    @Test
    func `scalar equality passes and records`() {
        expectEqual(2 + 2, 4)
        withKnownIssue { expectEqual(2 + 2, 5) }
    }

    @Test
    func `array equality reports element-wise divergence`() {
        expectEqual([1, 2, 3], [1, 2, 3])
        withKnownIssue { expectEqual([1, 2, 3], [1, 9, 3]) }
        withKnownIssue { expectEqual([1, 2], [1, 2, 3]) }
    }

    @Test
    func `array equality walks past the first divergence (no early return)`() {
        // Indices 1 and 3 both differ; the assert must keep going past the first instead
        // of returning after element[1], so multiple divergences are surfaced.
        withKnownIssue { expectEqual([1, 2, 3, 4], [1, 9, 3, 8]) }
    }

    @Test
    func `expectNotNil unwraps and returns the value`() {
        let value = expectNotNil(Optional(7))
        #expect(value == 7)
        withKnownIssue { _ = expectNotNil(Int?.none) }
    }

    @Test
    func `boolean asserts`() {
        expectTrue(true)
        expectFalse(false)
        withKnownIssue { expectTrue(false) }
        withKnownIssue { expectFalse(true) }
    }

    @Test
    func `typedFixture forces an explicit element type at the boundary`() {
        let rows: [Int] = typedFixture { [1, 2, 3] }
        expectEqual(rows, [1, 2, 3])
    }

    @Test
    func `count assert`() {
        expectCount([1, 2, 3], 3)
        withKnownIssue { expectCount([1, 2], 3) }
    }

    @Test
    func `expectNil and expectNotEqual pass and record`() {
        expectNil(Int?.none)
        expectNotEqual(1, 2)
        withKnownIssue { expectNil(Optional(5)) }
        withKnownIssue { expectNotEqual(3, 3) }
    }
}
