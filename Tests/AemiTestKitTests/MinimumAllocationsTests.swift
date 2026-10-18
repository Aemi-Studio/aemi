internal import AemiTestKit
import Foundation
import Testing

/// Whether this test binary was built without optimization.
private let isDebugBuild: Bool = {
    #if DEBUG
        true
    #else
        false
    #endif
}()

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

    @Test func `measuring an empty body counts nothing`() throws {
        let count = try #require(minimumAllocations(repeats: 3) {})
        #expect(count == 0, "the measurement itself allocated \(count) times")
    }

    /// Unoptimized Swift 6.3 allocates once per iteration of this loop: CI measured 10,000 for 10,000
    /// iterations. The counter is right; the debug code allocates. Swift 6.4 debug and every release
    /// build measure 0, so the loop is checked where the code under measurement is optimized.
    @Test(.disabled(if: isDebugBuild, "unoptimized code allocates per loop iteration under Swift 6.3"))
    func `a body that allocates nothing measures zero`() throws {
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
