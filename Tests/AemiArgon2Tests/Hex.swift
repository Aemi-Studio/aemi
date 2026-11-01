/// Bytes from a hex string, as the reference vectors store them.
func bytes(hex: String) -> [UInt8] {
    let digits = Array(hex.utf8)
    return stride(from: 0, to: digits.count, by: 2)
        .map { UInt8(value(of: digits[$0]) << 4 | value(of: digits[$0 + 1])) }
}

private func value(of digit: UInt8) -> UInt8 {
    digit >= 0x61 ? digit - 0x61 + 10 : digit - 0x30
}

/// Lowercase hex of bytes, so a failing comparison reads as the vectors do.
func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] }, as: UTF8.self)
}
