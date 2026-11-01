internal import CAemiArgon2

/// Comparisons whose time does not depend on where two secrets differ.
public enum ConstantTime {
    /// Whether `a` and `b` are equal, in a time that depends on their lengths only.
    public static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                adf_crypto_equal(left.baseAddress, right.baseAddress, left.count) == 1
            }
        }
    }

    /// Zeroes `bytes` in place, in a way the optimiser does not remove.
    public static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { adf_crypto_wipe($0.baseAddress, $0.count) }
    }

    static func wipe(_ words: inout [UInt64]) {
        words.withUnsafeMutableBytes { adf_crypto_wipe($0.baseAddress, $0.count) }
    }
}
