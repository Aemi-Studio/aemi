import AemiKernel
import Testing

struct CheckedMathTests {
    @Test func addingWithinBoundsReturnsSum() {
        #expect((2 as Int).checkedAdding(3) == 5)
        #expect(UInt8.max.checkedAdding(0) == UInt8.max)
    }

    @Test func addingOverflowReturnsNil() {
        #expect(Int.max.checkedAdding(1) == nil)
        #expect(UInt8.max.checkedAdding(1) == nil)
    }

    @Test func subtractingWithinBoundsReturnsDifference() {
        #expect((5 as Int).checkedSubtracting(3) == 2)
        #expect((0 as UInt8).checkedSubtracting(0) == 0)
    }

    @Test func subtractingOverflowReturnsNil() {
        #expect((0 as UInt8).checkedSubtracting(1) == nil)
        #expect(Int.min.checkedSubtracting(1) == nil)
    }

    @Test func multiplyingWithinBoundsReturnsProduct() {
        #expect((6 as Int).checkedMultiplied(by: 7) == 42)
        #expect((0 as Int).checkedMultiplied(by: Int.max) == 0)
    }

    @Test func multiplyingOverflowReturnsNil() {
        #expect(Int.max.checkedMultiplied(by: 2) == nil)
        #expect(UInt8(16).checkedMultiplied(by: 16) == nil)
    }
}
