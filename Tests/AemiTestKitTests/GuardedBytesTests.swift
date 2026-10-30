import AemiTestKit
import Testing

/// `GuardedBytes` (aemi ADR 0021): the bytes are the ones given, and one read beyond either guarded edge stops the program.
struct GuardedBytesTests {
    @Test(arguments: GuardedBytes.Edge.allCases)
    func `the bytes are the ones given, at every length`(edge: GuardedBytes.Edge) {
        for count in [0, 1, 7, 4095, 4096, 4097, 10_000] {
            let bytes = (0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let read = GuardedBytes.with(bytes, against: edge) { base in (0 ..< count).map { base[$0] } }
            #expect(read == bytes, "\(count) bytes against the \(edge)")
        }
    }

    @Test func `a read one past the end stops the program`() async {
        await #expect(processExitsWith: .failure) {
            let sink = GuardedBytes.with([1, 2, 3], against: .end) { base in base[3] }
            print(sink)
        }
    }

    @Test func `a read one before the start stops the program`() async {
        await #expect(processExitsWith: .failure) {
            let sink = GuardedBytes.with([1, 2, 3], against: .start) { base in (base - 1).pointee }
            print(sink)
        }
    }

    @Test func `the bytes can be written in place`() {
        let after = GuardedBytes.with([0, 0, 0]) { base -> [UInt8] in
            base[2] = 9
            return [base[0], base[1], base[2]]
        }
        #expect(after == [0, 0, 9])
    }
}
