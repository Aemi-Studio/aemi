// MARK: - SI (String Interning Runtime)

/// Runtime decoder for interned strings.
/// Reconstructs original strings from obfuscated byte storage.
public enum SI: Sendable {
    /// Resolves an interned string from its storage representation.
    /// - Parameters:
    ///   - d: Obfuscated byte array
    ///   - k: Interning key
    /// - Returns: The original string
    /// - Complexity: O(n) time, O(n) space where n = d.count
    @inlinable
    public static func v(_ d: [UInt8], _ k: UInt64) -> String {
        let n = d.count
        guard n > 0 else { return "" }

        // Regenerate permutation from key
        var g = _SIGen(k ^ 0xA5A5_A5A5_A5A5_A5A5)
        var p = ContiguousArray(0..<n)

        for i in stride(from: n - 1, through: 1, by: -1) {
            p.swapAt(i, Int(g.n() % UInt64(i + 1)))
        }

        // XOR with keystream and inverse-permute in single pass
        var h = _SIGen(k ^ 0x5A5A_5A5A_5A5A_5A5A)
        var o = ContiguousArray<UInt8>(repeating: 0, count: n)

        for (i, b) in d.enumerated() {
            o[p[i]] = b ^ UInt8(truncatingIfNeeded: h.n())
        }

        return String(decoding: o, as: UTF8.self)
    }
}

// MARK: - Internal Generator

@usableFromInline
internal struct _SIGen: ~Copyable {
    @usableFromInline var s: UInt64

    @inlinable
    init(_ v: UInt64) { s = v }

    @inlinable
    mutating func n() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
