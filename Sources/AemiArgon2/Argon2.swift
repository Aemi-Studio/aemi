internal import CAemiArgon2

/// Argon2 (RFC 9106, version 0x13): a password's tag, made slow and memory-hard by its parameters.
///
/// The memory fill runs in C (`CAemiArgon2`): NEON with SHA3 on Apple silicon, AVX2 or SSSE3 on x86-64, the lanes of a
/// slice on `threads` threads. No step branches on a secret; Argon2d, and Argon2id after its first half pass, read
/// blocks chosen by the data, which RFC 9106 accepts for those variants. Every buffer holding a secret is wiped.
public enum Argon2 {
    /// Which blocks a pass reads: chosen by the data (`d`), independently of it (`i`), or `i` for the first half pass
    /// then `d` (`id`, the one RFC 9106 recommends).
    public enum Variant: UInt32, Sendable, Equatable {
        case d = 0
        case i = 1
        case id = 2
    }

    /// Why a tag could not be made.
    public enum Failure: Error, Sendable, Equatable {
        /// Lanes must be 1 to 2^24 - 1.
        case lanesOutOfRange
        /// Passes must be 1 or more.
        case noPasses
        /// Memory must be at least 8 KiB per lane.
        case memoryBelowEightBlocksPerLane
        /// Memory must fit 32 bits of KiB.
        case memoryTooLarge
        /// The tag must be 4 bytes or more.
        case tagTooShort
        /// The salt must be 8 bytes or more.
        case saltTooShort
        /// An input or the tag is over 2^32 - 1 bytes.
        case inputTooLong
        /// The memory could not be had.
        case outOfMemory
    }

    /// The cost: memory in KiB, passes over it, lanes, and the tag's length in bytes.
    public struct Parameters: Sendable, Equatable {
        public let variant: Variant
        public let memoryKiB: Int
        public let passes: Int
        public let lanes: Int
        public let tagLength: Int

        /// Parameters within RFC 9106's bounds, or the bound they cross.
        public init(variant: Variant, memoryKiB: Int, passes: Int, lanes: Int, tagLength: Int) throws(Failure) {
            guard (1 ..< (1 << 24)).contains(lanes) else { throw .lanesOutOfRange }
            guard passes >= 1 else { throw .noPasses }
            guard passes <= UInt32.max else { throw .inputTooLong }
            guard memoryKiB <= UInt32.max else { throw .memoryTooLarge }
            guard memoryKiB >= 8 * lanes else { throw .memoryBelowEightBlocksPerLane }
            guard tagLength >= 4 else { throw .tagTooShort }
            guard tagLength <= UInt32.max else { throw .inputTooLong }
            self.variant = variant
            self.memoryKiB = memoryKiB
            self.passes = passes
            self.lanes = lanes
            self.tagLength = tagLength
        }
    }

    /// The tag of `password`, salted, optionally keyed by `secret` and bound to `associatedData`. `threads` fill lanes
    /// in parallel and do not change the tag.
    public static func hash(
        password: [UInt8],
        salt: [UInt8],
        secret: [UInt8] = [],
        associatedData: [UInt8] = [],
        parameters: Parameters,
        threads: Int = 1,
        backend: CryptoBackend = .fastest
    ) throws(Failure) -> [UInt8] {
        guard salt.count >= 8 else { throw .saltTooShort }
        for input in [password, salt, secret, associatedData] where input.count > UInt32.max { throw .inputTooLong }
        let lanes = parameters.lanes
        let laneLength = parameters.memoryKiB / (4 * lanes) * 4
        let blocks = laneLength * lanes
        guard let memory = adf_argon2_allocate(blocks) else { throw .outOfMemory }
        defer { adf_argon2_release(memory, blocks) }
        var seed = initialHash(password, salt, secret, associatedData, parameters)
        defer { ConstantTime.wipe(&seed) }
        for lane in 0 ..< lanes {
            for column in 0 ..< 2 {
                var input = seed + le32(column) + le32(lane)
                var block = variableHash(input, length: 1024, backend: backend)
                store(block, into: memory + (lane * laneLength + column) * 128)
                ConstantTime.wipe(&block)
                ConstantTime.wipe(&input)
            }
        }
        var fill = adf_argon2_fill_t(
            memory: memory,
            lanes: UInt32(lanes),
            lane_length: UInt32(laneLength),
            passes: UInt32(parameters.passes),
            type: parameters.variant.rawValue,
            threads: UInt32(clamping: max(1, threads)),
            backend: backend.rawValue
        )
        adf_argon2_fill(&fill)
        var last = [UInt8](repeating: 0, count: 1024)
        for lane in 0 ..< lanes {
            let block = memory + (lane * laneLength + laneLength - 1) * 128
            for word in 0 ..< 128 {
                for byte in 0 ..< 8 {
                    last[word * 8 + byte] ^= UInt8(truncatingIfNeeded: block[word] >> UInt64(byte * 8))
                }
            }
        }
        defer { ConstantTime.wipe(&last) }
        return variableHash(last, length: parameters.tagLength, backend: backend)
    }

    /// Whether `tag` is `password`'s, compared in constant time.
    public static func verify(
        _ tag: [UInt8],
        password: [UInt8],
        salt: [UInt8],
        secret: [UInt8] = [],
        associatedData: [UInt8] = [],
        parameters: Parameters,
        threads: Int = 1
    ) throws(Failure) -> Bool {
        var computed = try hash(
            password: password,
            salt: salt,
            secret: secret,
            associatedData: associatedData,
            parameters: parameters,
            threads: threads
        )
        defer { ConstantTime.wipe(&computed) }
        return ConstantTime.equal(computed, tag)
    }

    /// H0 (RFC 9106, 3.2 step 1): every parameter and input, length-prefixed, in BLAKE2b-512.
    private static func initialHash(
        _ password: [UInt8],
        _ salt: [UInt8],
        _ secret: [UInt8],
        _ associatedData: [UInt8],
        _ parameters: Parameters
    ) -> [UInt8] {
        // swiftlint:disable:next force_try
        var hasher = try! BLAKE2b(length: 64)
        for value in [parameters.lanes, parameters.tagLength, parameters.memoryKiB, parameters.passes, 0x13] {
            hasher.update(le32(value))
        }
        hasher.update(le32(Int(parameters.variant.rawValue)))
        for input in [password, salt, secret, associatedData] {
            hasher.update(le32(input.count))
            hasher.update(input)
        }
        return hasher.finalize()
    }

    private static func store(_ bytes: [UInt8], into block: UnsafeMutablePointer<UInt64>) {
        for word in 0 ..< 128 {
            var value: UInt64 = 0
            for byte in 0 ..< 8 { value |= UInt64(bytes[word * 8 + byte]) << UInt64(byte * 8) }
            block[word] = value
        }
    }

    static func le32(_ value: Int) -> [UInt8] {
        let value = UInt32(truncatingIfNeeded: value)
        return [
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)
        ]
    }
}
