#if canImport(CommonCrypto)
    import CommonCrypto
#endif

/// Cryptographic content digests: SHA-256 (FIPS 180-4), for content identity that must hold against a chosen input
/// (snapshot manifests, evidence checksums), where ``XXH64`` and ``WyHash`` are only fast.
///
/// On Apple platforms the digest is CommonCrypto's, which uses the CPU's SHA instructions; elsewhere it is the portable
/// implementation below, which the tests check against the NIST vectors and, on Apple platforms, against CommonCrypto
/// over random inputs. No package is needed on either side.
public enum ContentDigest {
    /// The size of a SHA-256 digest in bytes.
    public static let sha256ByteCount = 32

    /// The SHA-256 digest of `bytes`.
    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }

    /// The SHA-256 digest of `bytes`.
    public static func sha256(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }

    /// The SHA-256 digest of `bytes` in lower-case hexadecimal.
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        String(decoding: Hex.encode(sha256(bytes)), as: UTF8.self)
    }

    /// An incremental SHA-256: ``update(_:)`` with the input in pieces, then ``finalize()`` once.
    public struct SHA256: Sendable {
        #if canImport(CommonCrypto)
            private var context = CC_SHA256_CTX()
        #else
            private var state = PortableSHA256()
        #endif

        public init() {
            #if canImport(CommonCrypto)
                _ = unsafe CC_SHA256_Init(&context)
            #endif
        }

        public mutating func update(_ bytes: [UInt8]) {
            update(bytes[...])
        }

        public mutating func update(_ bytes: ArraySlice<UInt8>) {
            #if canImport(CommonCrypto)
                bytes.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    // CC_LONG is 32 bits: feed at most 1 GiB per call.
                    var offset = 0
                    while offset < buffer.count {
                        let count = min(buffer.count - offset, 1 << 30)
                        _ = unsafe CC_SHA256_Update(&context, base + offset, CC_LONG(count))
                        offset += count
                    }
                }
            #else
                state.update(bytes)
            #endif
        }

        /// The digest of everything given to ``update(_:)``. Call once.
        public mutating func finalize() -> [UInt8] {
            #if canImport(CommonCrypto)
                var digest = [UInt8](repeating: 0, count: ContentDigest.sha256ByteCount)
                digest.withUnsafeMutableBufferPointer { buffer in
                    _ = unsafe CC_SHA256_Final(buffer.baseAddress, &context)
                }
                return digest
            #else
                return state.finalize()
            #endif
        }
    }
}

/// SHA-256 as FIPS 180-4 specifies it, in plain Swift: the digest outside Apple platforms, and the reference the tests
/// hold CommonCrypto to.
struct PortableSHA256: Sendable {
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2
    ]

    private var h: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    ]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    init() { buffer.reserveCapacity(64) }

    mutating func update(_ bytes: ArraySlice<UInt8>) {
        length &+= UInt64(bytes.count)
        var index = bytes.startIndex
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[index ..< index + take])
            index += take
            guard buffer.count == 64 else { return }
            compress(buffer[...])
            buffer.removeAll(keepingCapacity: true)
        }
        while bytes.endIndex - index >= 64 {
            compress(bytes[index ..< index + 64])
            index += 64
        }
        buffer.append(contentsOf: bytes[index...])
    }

    mutating func finalize() -> [UInt8] {
        let bits = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        var index = tail.startIndex
        while index < tail.endIndex {
            compress(tail[index ..< index + 64])
            index += 64
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in h {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        var offset = block.startIndex
        for t in 0 ..< 16 {
            w[t] =
                UInt32(block[offset]) << 24 | UInt32(block[offset + 1]) << 16 | UInt32(block[offset + 2]) << 8
                | UInt32(block[offset + 3])
            offset += 4
        }
        for t in 16 ..< 64 {
            let s0 = Self.rotr(w[t - 15], 7) ^ Self.rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = Self.rotr(w[t - 2], 17) ^ Self.rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for t in 0 ..< 64 {
            let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ choice &+ Self.k[t] &+ w[t]
            let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
        h[5] &+= f
        h[6] &+= g
        h[7] &+= hh
    }
}
