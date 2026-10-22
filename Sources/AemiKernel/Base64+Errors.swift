extension Base64 {
    /// Why a decode failed. Offsets are byte offsets into the input (not into the decoded output), so a
    /// caller can point at the exact byte. Under ``ErrorReporting/uniform`` every cause that depends on
    /// the *content* of the input is reported as ``malformed``.
    public enum DecodeError: Error, Sendable, Hashable {
        /// `byte` at `offset` is not in the alphabet and is not skipped by the whitespace policy.
        case invalidByte(UInt8, offset: Int)
        /// The symbol count cannot be a Base64 encoding (a lone trailing sextet), or the padding the
        /// policy requires is missing so the length is not a multiple of 4.
        case invalidLength
        /// The `=` run starting at `offset` is misplaced, the wrong length for the trailing group, not
        /// allowed by the policy, or followed by more data.
        case invalidPadding(offset: Int)
        /// The unused low bits of the final symbol (at `offset`) are not zero, so a second text would
        /// decode to the same bytes. Only raised under ``TrailingBitsPolicy/canonical``.
        case nonCanonicalBits(offset: Int)
        /// A line holds more than ``Options/lineLength`` characters; `offset` is the first byte over.
        case lineTooLong(offset: Int)
        /// The decoded size would exceed ``Options/maximumDecodedSize`` (`limit`).
        case outputTooLarge(limit: Int)
        /// The caller's output buffer is too small for the decoded bytes.
        case outputBufferTooSmall
        /// The input is malformed; the cause is withheld (``ErrorReporting/uniform``).
        case malformed

        /// This error as reported under ``ErrorReporting/uniform``: content-dependent causes collapse to
        /// ``malformed``; size and buffer causes depend only on the caller's configuration and stay.
        var uniform: DecodeError {
            switch self {
                case .invalidByte, .invalidLength, .invalidPadding, .nonCanonicalBits, .lineTooLong:
                    return .malformed
                case .outputTooLarge, .outputBufferTooSmall, .malformed:
                    return self
            }
        }
    }

    /// Why an encode into a caller-provided buffer failed.
    public enum EncodeError: Error, Sendable, Hashable {
        /// The output buffer holds fewer than `required` bytes.
        case outputBufferTooSmall(required: Int)
        /// The encoded size does not fit in `Int`.
        case inputTooLarge
    }
}
