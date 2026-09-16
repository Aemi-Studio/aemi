struct InternedObfuscation {
    let expressionSource: String

    static func make(for string: String, strategy: InternedObfuscationStrategy, backend: InternedObfuscationBackend)
        -> InternedObfuscation
    {
        let inputBytes = Array(string.utf8)
        let keys: [UInt64] =
            switch strategy {
                case .standard:
                    [UInt64.random(in: .min ... .max)]
                case .layered:
                    [
                        UInt64.random(in: .min ... .max),
                        UInt64.random(in: .min ... .max)
                    ]
            }

        let obfuscated = obfuscate(bytes: inputBytes, keys: keys)
        let bytesLiteral = formatBytesLiteral(obfuscated)
        let keyLiterals = keys.map(formatKeyLiteral)

        let expressionSource: String
        switch backend {
            case .shared:
                if keyLiterals.count == 1, let keyLiteral = keyLiterals.first {
                    expressionSource = "SI.v([\(bytesLiteral)], \(keyLiteral))"
                } else {
                    let keysLiteral = keyLiterals.joined(separator: ", ")
                    expressionSource = "SI.v([\(bytesLiteral)], [\(keysLiteral)])"
                }
            case .inlined:
                expressionSource = inlineExpressionSource(bytesLiteral: bytesLiteral, keyLiterals: keyLiterals)
        }

        return InternedObfuscation(expressionSource: expressionSource)
    }

    private static func inlineExpressionSource(bytesLiteral: String, keyLiterals: [String]) -> String {
        let keysLiteral = keyLiterals.joined(separator: ", ")
        return """
            {
                func _internedNext(_ state: inout UInt64) -> UInt64 {
                    state &+= 0x9E37_79B9_7F4A_7C15
                    var z = state
                    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                    return z ^ (z >> 31)
                }

                func _internedDecode(_ data: [UInt8], _ key: UInt64) -> [UInt8] {
                    let count = data.count
                    guard count > 0 else { return [] }

                    var shuffleState = key ^ 0xA5A5_A5A5_A5A5_A5A5
                    var permutation = Array(0..<count)
                    for index in stride(from: count - 1, through: 1, by: -1) {
                        permutation.swapAt(index, Int(_internedNext(&shuffleState) % UInt64(index + 1)))
                    }

                    var streamState = key ^ 0x5A5A_5A5A_5A5A_5A5A
                    var output = [UInt8](repeating: 0, count: count)
                    for (index, byte) in data.enumerated() {
                        output[permutation[index]] = byte ^ UInt8(truncatingIfNeeded: _internedNext(&streamState))
                    }

                    return output
                }

                var _internedBytes: [UInt8] = [\(bytesLiteral)]
                let _internedKeys: [UInt64] = [\(keysLiteral)]
                for _internedKey in _internedKeys.reversed() {
                    _internedBytes = _internedDecode(_internedBytes, _internedKey)
                }

                return String(decoding: _internedBytes, as: UTF8.self)
            }()
            """
    }

    private static func obfuscate(bytes: [UInt8], keys: [UInt64]) -> [UInt8] {
        var result = bytes

        for key in keys {
            result = obfuscate(bytes: result, key: key)
        }

        return result
    }

    private static func obfuscate(bytes: [UInt8], key: UInt64) -> [UInt8] {
        let n = bytes.count
        guard n > 0 else { return [] }

        var shuffleGen = SplitMix64(seed: key ^ 0xA5A5_A5A5_A5A5_A5A5)
        var permutation = Array(0 ..< n)

        for i in stride(from: n - 1, through: 1, by: -1) {
            permutation.swapAt(i, Int(shuffleGen.next() % UInt64(i + 1)))
        }

        var permuted = [UInt8](repeating: 0, count: n)
        for i in 0 ..< n {
            permuted[i] = bytes[permutation[i]]
        }

        var streamGen = SplitMix64(seed: key ^ 0x5A5A_5A5A_5A5A_5A5A)
        var obfuscated = [UInt8](repeating: 0, count: n)

        for i in 0 ..< n {
            obfuscated[i] = permuted[i] ^ UInt8(truncatingIfNeeded: streamGen.next())
        }

        return obfuscated
    }

    private static func formatBytesLiteral(_ bytes: [UInt8]) -> String {
        bytes.map { "0x" + String($0, radix: 16, uppercase: true).paddedToTwo() }.joined(separator: ", ")
    }

    private static func formatKeyLiteral(_ key: UInt64) -> String {
        "0x" + String(key, radix: 16, uppercase: true)
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
