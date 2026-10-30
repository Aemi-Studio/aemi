import AemiKernels
import Testing

// The ASCII prefix of UTF-16LE text (NTFS names, Windows formats): how many units are below 0x80, copied as bytes.
// `.fastest` equals `.scalar` and an independent loop, with the first non-ASCII unit at every position.
struct AemiKernelsUTF16Tests {
    static func prefix(_ units: [UInt16], _ backend: AemiKernels.Backend) -> (Int, [UInt8]) {
        let raw = units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        var ascii = [UInt8](repeating: 0xEE, count: units.count)
        let copied = raw.withUnsafeBufferPointer { source in
            ascii.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let to = target.baseAddress else { return 0 }
                return AemiKernels.asciiPrefix(utf16LE: from, units: units.count, into: to, backend: backend)
            }
        }
        return (copied, Array(ascii.prefix(copied)))
    }

    @Test func theFirstNonASCIIUnitStopsTheCopyWherever_ItIs() {
        for length in 0 ... 70 {
            for stop in [nil] + Array(0 ..< length).map(Optional.some) {
                for blocker: UInt16 in [0x80, 0x00FF, 0x0100, 0xD83D, 0xFFFF] {
                    var units = (0 ..< length).map { UInt16(0x20 + ($0 % 90)) }
                    if let stop { units[stop] = blocker }
                    let expectedCount = stop ?? length
                    let expected = units.prefix(expectedCount).map { UInt8($0) }
                    for backend: AemiKernels.Backend in [.fastest, .scalar] {
                        let (count, bytes) = Self.prefix(units, backend)
                        #expect(
                            count == expectedCount && bytes == expected,
                            "\(backend), length \(length), stop \(String(describing: stop))")
                    }
                }
            }
        }
    }
}
