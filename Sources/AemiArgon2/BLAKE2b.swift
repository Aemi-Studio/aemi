internal import CAemiArgon2

/// BLAKE2b (RFC 7693): a digest of 1 to 64 bytes, keyed or not, over input given whole or in pieces.
public struct BLAKE2b: Sendable {
    /// Why a hasher could not be made.
    public enum Failure: Error, Sendable, Equatable {
        /// The digest length is not between 1 and 64 bytes.
        case lengthOutOfRange
        /// The key is longer than 64 bytes.
        case keyTooLong
    }

    static let blockLength = 128
    static let initialValue: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179
    ]

    private var state: [UInt64]
    /// Input not compressed yet: at most a block, kept because the last block is compressed differently.
    private var pending: [UInt8] = []
    /// Bytes compressed so far, RFC 7693's 128-bit counter `t`.
    private var countLow: UInt64 = 0
    private var countHigh: UInt64 = 0
    private let length: Int
    private let backend: CryptoBackend

    /// A hasher for a digest of `length` bytes, keyed by `key` when it is not empty.
    public init(length: Int, key: [UInt8] = [], backend: CryptoBackend = .fastest) throws(Failure) {
        guard (1 ... 64).contains(length) else { throw .lengthOutOfRange }
        guard key.count <= 64 else { throw .keyTooLong }
        self.length = length
        self.backend = backend
        state = Self.initialValue
        state[0] ^= 0x0101_0000 ^ UInt64(key.count) << 8 ^ UInt64(length)
        pending.reserveCapacity(Self.blockLength)
        if !key.isEmpty {
            // The key is the first block, padded with zeros (RFC 7693, 3.3).
            var block = key + [UInt8](repeating: 0, count: Self.blockLength - key.count)
            update(block)
            ConstantTime.wipe(&block)
        }
    }

    /// Adds `bytes` to the input.
    public mutating func update(_ bytes: [UInt8]) {
        var next = 0
        while next < bytes.count {
            if pending.count == Self.blockLength {
                compress(last: false)
                pending.removeAll(keepingCapacity: true)
            }
            let taken = min(Self.blockLength - pending.count, bytes.count - next)
            pending += bytes[next ..< next + taken]
            next += taken
        }
    }

    /// The digest of everything given. The hasher's state is wiped.
    public consuming func finalize() -> [UInt8] {
        compress(last: true)
        var digest = [UInt8](repeating: 0, count: length)
        for index in 0 ..< length {
            digest[index] = UInt8(truncatingIfNeeded: state[index >> 3] >> UInt64((index & 7) * 8))
        }
        ConstantTime.wipe(&state)
        ConstantTime.wipe(&pending)
        return digest
    }

    /// The digest of `data`, in one call.
    public static func hash(
        _ data: [UInt8],
        length: Int,
        key: [UInt8] = [],
        backend: CryptoBackend = .fastest
    ) throws(Failure) -> [UInt8] {
        var hasher = try BLAKE2b(length: length, key: key, backend: backend)
        hasher.update(data)
        return hasher.finalize()
    }

    private mutating func compress(last: Bool) {
        let (sum, carry) = countLow.addingReportingOverflow(UInt64(pending.count))
        countLow = sum
        if carry { countHigh &+= 1 }
        var block = [UInt64](repeating: 0, count: 16)
        for (index, byte) in pending.enumerated() { block[index >> 3] |= UInt64(byte) << UInt64((index & 7) * 8) }
        let (low, high, backend) = (countLow, countHigh, backend.rawValue)
        state.withUnsafeMutableBufferPointer { state in
            block.withUnsafeBufferPointer {
                adf_blake2b_compress(state.baseAddress, $0.baseAddress, low, high, last ? 1 : 0, backend)
            }
        }
        ConstantTime.wipe(&block)
    }
}
