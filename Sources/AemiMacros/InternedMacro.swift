import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Interned (Accessor Macro)

public struct InternedMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            throw macroError(node, domain: "InternedStrings", "@Interned can only be applied to a property")
        }

        guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first else {
            throw macroError(node, domain: "InternedStrings", "@Interned can only be applied to a single property")
        }

        guard binding.accessorBlock == nil else {
            throw macroError(node, domain: "InternedStrings", "@Interned cannot be applied to a computed property")
        }

        guard let value = extractValue(from: node, binding: binding) else {
            throw macroError(node, domain: "InternedStrings", "@Interned requires a string literal (as argument or initializer)")
        }

        let key = UInt64.random(in: .min ... .max)
        let obfuscatedBytes = obfuscate(string: value, key: key)
        let bytesLiteral = formatBytesLiteral(obfuscatedBytes)

        let getter: AccessorDeclSyntax =
            """
            get {
                SI.v([\(raw: bytesLiteral)], \(literal: key))
            }
            """

        return [getter]
    }

    // MARK: - Value Extraction

    private static func extractValue(from attribute: AttributeSyntax, binding: PatternBindingSyntax) -> String? {
        if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
           let first = arguments.first?.expression,
           let text = extractStringLiteral(from: first) {
            return text
        }

        if let initializer = binding.initializer?.value,
           let text = extractStringLiteral(from: initializer) {
            return text
        }

        return nil
    }

    private static func extractStringLiteral(from expr: ExprSyntax) -> String? {
        guard let literal = expr.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              case let .stringSegment(segment) = literal.segments.first
        else {
            return nil
        }
        return segment.content.text
    }

    // MARK: - Obfuscation

    static func obfuscate(string: String, key: UInt64) -> [UInt8] {
        let bytes = Array(string.utf8)
        let n = bytes.count

        guard n > 0 else { return [] }

        var shuffleGen = SplitMix64(seed: key ^ 0xA5A5_A5A5_A5A5_A5A5)
        var permutation = Array(0..<n)

        for i in stride(from: n - 1, through: 1, by: -1) {
            permutation.swapAt(i, Int(shuffleGen.next() % UInt64(i + 1)))
        }

        var permuted = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            permuted[i] = bytes[permutation[i]]
        }

        var streamGen = SplitMix64(seed: key ^ 0x5A5A_5A5A_5A5A_5A5A)
        var obfuscated = [UInt8](repeating: 0, count: n)

        for i in 0..<n {
            obfuscated[i] = permuted[i] ^ UInt8(truncatingIfNeeded: streamGen.next())
        }

        return obfuscated
    }

    private static func formatBytesLiteral(_ bytes: [UInt8]) -> String {
        bytes.map { "0x" + String($0, radix: 16, uppercase: true).paddedToTwo() }.joined(separator: ", ")
    }

    // MARK: - PRNG

    struct SplitMix64 {
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
