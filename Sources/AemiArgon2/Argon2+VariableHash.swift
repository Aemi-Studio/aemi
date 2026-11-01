extension Argon2 {
    /// H' (RFC 9106, 3.3): BLAKE2b stretched to any length, 32 bytes of each 64-byte link and the whole last one.
    static func variableHash(_ input: [UInt8], length: Int, backend: CryptoBackend) -> [UInt8] {
        // The lengths below are 1 to 64 by construction, so BLAKE2b cannot refuse them.
        // swiftlint:disable force_try
        var prefixed = le32(length) + input
        defer { ConstantTime.wipe(&prefixed) }
        if length <= 64 { return try! BLAKE2b.hash(prefixed, length: length, backend: backend) }
        let links = (length + 31) / 32 - 2
        var output: [UInt8] = []
        output.reserveCapacity(length)
        var link = try! BLAKE2b.hash(prefixed, length: 64, backend: backend)
        output += link[..<32]
        for _ in 1 ..< links {
            link = try! BLAKE2b.hash(link, length: 64, backend: backend)
            output += link[..<32]
        }
        var tail = try! BLAKE2b.hash(link, length: length - 32 * links, backend: backend)
        // swiftlint:enable force_try
        output += tail
        ConstantTime.wipe(&link)
        ConstantTime.wipe(&tail)
        return output
    }
}
