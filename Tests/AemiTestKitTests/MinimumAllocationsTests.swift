internal import AemiTestKit
import Foundation
import Testing

@Suite("Allocation measurement helpers")
struct MinimumAllocationsTests {
    @Test func `the minimum across repeats still counts every allocation the body makes`() throws {
        var sink: [String] = []
        for _ in 0 ..< 100 { sink.append(String(repeating: "x", count: 64)) }
        sink.removeAll()

        let count = try #require(
            minimumAllocations(repeats: 3) {
                for _ in 0 ..< 100 { sink.append(String(repeating: "x", count: 64)) }
            })
        #expect(count >= 100, "expected at least one allocation per string, measured \(count)")
    }

    @Test func `a body that allocates nothing measures zero`() throws {
        var total = 0
        let count = try #require(
            minimumAllocations(repeats: 3) {
                for index in 0 ..< 10_000 { total &+= index }
            })
        #expect(count == 0, "expected zero, measured \(count)")
        #expect(total > 0)
    }

    @Test func `a single repeat is accepted`() throws {
        let count = try #require(minimumAllocations(repeats: 1) { _ = [UInt8](repeating: 0, count: 1) })
        #expect(count >= 0)
    }
}
