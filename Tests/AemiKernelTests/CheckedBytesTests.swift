import AemiKernel
import Testing

/// `CheckedBytes`, promoted from AemiRegex (aemi ADR 0018): every read is bounds-checked, in release builds too.
struct CheckedBytesTests {
    @Test func `reads inside the buffer return the bytes, and it is a collection of them`() {
        let raw: [UInt8] = [1, 2, 3]
        raw.withUnsafeBufferPointer { buffer in
            let bytes = CheckedBytes(buffer)
            #expect(bytes.count == 3 && bytes.startIndex == 0 && bytes.endIndex == 3)
            #expect((0 ..< 3).map { bytes[$0] } == raw)
            #expect(Array(bytes) == raw)
        }
    }

    @Test func `a read one past the end stops the program`() async {
        await #expect(processExitsWith: .failure) {
            let bytes: [UInt8] = [1, 2, 3]
            bytes.withUnsafeBufferPointer { _ = CheckedBytes($0)[3] }
        }
    }

    @Test func `a negative read stops the program`() async {
        await #expect(processExitsWith: .failure) {
            let bytes: [UInt8] = [1, 2, 3]
            bytes.withUnsafeBufferPointer { _ = CheckedBytes($0)[-1] }
        }
    }
}
