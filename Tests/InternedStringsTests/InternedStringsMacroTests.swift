import Foundation
import InternedStrings
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import AemiMacros

private let testMacros: [String: Macro.Type] = [
    "Interned": InternedMacro.self,
    "InlinedInterned": InternedMacro.self
]

// MARK: - Roundtrip Tests

@Suite("Roundtrip")
struct RoundtripTests {
    @Test("Empty string")
    func emptyString() {
        let key: UInt64 = 0x1234_5678_9ABC_DEF0
        let original = ""
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)
        let decoded = SI.v(obfuscated, key)

        #expect(decoded == original)
        #expect(obfuscated.isEmpty)
    }

    @Test("ASCII string")
    func asciiString() {
        let key: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        let original = "_privateSetFrame:"
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)
        let decoded = SI.v(obfuscated, key)

        #expect(decoded == original)
        #expect(obfuscated.count == original.utf8.count)
    }

    @Test("Unicode/emoji")
    func unicodeString() {
        let key: UInt64 = 0x0123_4567_89AB_CDEF
        let original = "Hello 世界 🌍 émojis"
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)
        let decoded = SI.v(obfuscated, key)

        #expect(decoded == original)
    }

    @Test("Long string")
    func longString() {
        let key: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        let original = String(repeating: "abcdefghij", count: 100)
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)
        let decoded = SI.v(obfuscated, key)

        #expect(decoded == original)
    }

    @Test("Single character")
    func singleChar() {
        let key: UInt64 = 0x0000_0000_0000_0001
        let original = "X"
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)
        let decoded = SI.v(obfuscated, key)

        #expect(decoded == original)
    }
}

// MARK: - Determinism Tests

@Suite("Determinism")
struct DeterminismTests {
    @Test("Same key produces same output")
    func sameKey() {
        let key: UInt64 = 0xABCD_EF01_2345_6789
        let original = "deterministic test"

        let first = TestObfuscator.obfuscate(string: original, key: key)
        let second = TestObfuscator.obfuscate(string: original, key: key)

        #expect(first == second)
    }

    @Test("Different keys produce different output")
    func differentKeys() {
        let original = "same input"

        let first = TestObfuscator.obfuscate(string: original, key: 0x1111)
        let second = TestObfuscator.obfuscate(string: original, key: 0x2222)

        #expect(first != second)
    }
}

// MARK: - Obfuscation Quality Tests

@Suite("Obfuscation Quality")
struct ObfuscationQualityTests {
    @Test("Output differs from input bytes")
    func outputDiffers() {
        let key: UInt64 = 0x9876_5432_1098_7654
        let original = "test string"
        let originalBytes = Array(original.utf8)
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)

        let differentCount = zip(originalBytes, obfuscated).filter { $0 != $1 }.count
        #expect(differentCount > originalBytes.count / 2)
    }

    @Test("No plaintext substrings leak")
    func noPlaintextLeakage() {
        let key: UInt64 = 0xFEDC_BA98_7654_3210
        let original = "_privateSetFrame:"
        let obfuscated = TestObfuscator.obfuscate(string: original, key: key)

        let originalBytes = Array(original.utf8)
        for i in 0 ..< (originalBytes.count - 3) {
            let substring = Array(originalBytes[i ..< (i + 4)])
            let found = obfuscated.indices.dropLast(3)
                .contains { j in
                    Array(obfuscated[j ..< (j + 4)]) == substring
                }
            #expect(!found, "Found plaintext substring at index \(i)")
        }
    }
}

// MARK: - Macro Expansion Tests

// The macro derives a fresh random key on every expansion, so the expanded source cannot be
// compared against a fixed string. These tests call the macro directly and verify the shape of
// the generated getter plus a semantic roundtrip: the emitted `SI.v(bytes, key)` call must
// decode back to the original literal.
@Suite("Macro Expansion")
struct MacroExpansionTests {
    @Test("Property with argument form")
    func argumentForm() throws {
        let getter = try expandInternedGetter("@Interned(\"hello\") static var greeting: String")
        try expectDecodes(getter, to: "hello")
    }

    @Test("Property with initializer form")
    func initializerForm() throws {
        let getter = try expandInternedGetter("@Interned static var greeting = \"hello\"")
        try expectDecodes(getter, to: "hello")
    }

    @Test("Instance property")
    func instanceProperty() throws {
        let getter = try expandInternedGetter("@Interned(\"value\") var instance: String")
        try expectDecodes(getter, to: "value")
    }

    @Test("Let binding works")
    func letBindingWorks() throws {
        let getter = try expandInternedGetter("@Interned(\"x\") static let x: String")
        try expectDecodes(getter, to: "x")
    }

    /// Expands `@Interned` on the given single-property declaration and returns the generated
    /// getter's source text.
    private func expandInternedGetter(
        _ source: String, sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws -> String {
        let decl: DeclSyntax = "\(raw: source)"
        let varDecl = try #require(
            decl.as(VariableDeclSyntax.self), sourceLocation: sourceLocation)
        let attribute = try #require(
            varDecl.attributes.first?.as(AttributeSyntax.self), sourceLocation: sourceLocation)
        let accessors = try InternedMacro.expansion(
            of: attribute,
            providingAccessorsOf: varDecl,
            in: BasicMacroExpansionContext())
        #expect(accessors.count == 1, sourceLocation: sourceLocation)
        let getter = try #require(accessors.first, sourceLocation: sourceLocation).description
        #expect(getter.contains("get"), sourceLocation: sourceLocation)
        #expect(getter.contains("SI.v("), sourceLocation: sourceLocation)
        return getter
    }

    /// Parses `SI.v([0x…, …], key)` out of the generated getter and checks that the runtime
    /// deobfuscator recovers the original literal.
    private func expectDecodes(
        _ getter: String, to expected: String, sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws {
        let open = try #require(getter.firstIndex(of: "["), sourceLocation: sourceLocation)
        let close = try #require(getter.firstIndex(of: "]"), sourceLocation: sourceLocation)
        let bytes: [UInt8] = try getter[getter.index(after: open) ..< close]
            .split(separator: ",")
            .map { chunk in
                let hex = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
                return try #require(UInt8(digits, radix: 16), sourceLocation: sourceLocation)
            }
        let afterBytes = getter[getter.index(after: close)...]
        let keyText =
            afterBytes
            .drop(while: { $0 == "," || $0 == " " })
            .prefix(while: { $0.isHexDigit || $0 == "x" || $0 == "_" })
        let normalizedKey = keyText.replacingOccurrences(of: "_", with: "")
        let key = try #require(
            normalizedKey.hasPrefix("0x")
                ? UInt64(normalizedKey.dropFirst(2), radix: 16)
                : UInt64(normalizedKey),
            sourceLocation: sourceLocation)
        #expect(SI.v(bytes, key) == expected, sourceLocation: sourceLocation)
    }
}

// MARK: - Diagnostic Tests

@Suite("Diagnostics")
struct DiagnosticTests {
    @Test("Error on missing value")
    func errorOnMissingValue() {
        assertMacroExpansion(
            """
            @Interned static var x: String
            """,
            expandedSource: """
                static var x: String
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Interned requires a string literal (as argument or initializer)", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    @Test("Error on computed property")
    func errorOnComputedProperty() {
        assertMacroExpansion(
            """
            @Interned("x") static var x: String { "y" }
            """,
            expandedSource: """
                static var x: String { "y" }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Interned cannot be applied to properties with accessors or observers", line: 1, column: 1
                )
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on non-string property`() {
        assertMacroExpansion(
            """
            @Interned("x") static var count: Int
            """,
            expandedSource: """
                static var count: Int
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Interned can only be applied to String properties", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on multi-binding declaration`() {
        assertMacroExpansion(
            """
            @Interned("x") static var first: String, second: String
            """,
            expandedSource: """
                static var first: String, second: String
                """,
            diagnostics: [
                DiagnosticSpec(message: "accessor macro can only be applied to a single variable", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on string interpolation`() {
        assertMacroExpansion(
            #"""
            @Interned("hello \(name)") static var greeting: String
            """#,
            expandedSource: """
                static var greeting: String
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Interned does not support string interpolation", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on non-literal freestanding input`() {
        assertMacroExpansion(
            """
            let value = "hello"
            let greeting = #Interned(value)
            """,
            expandedSource: """
                let value = "hello"
                let greeting = #Interned(value)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#Interned requires a string literal or array literal of strings", line: 2, column: 16)
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on invalid strategy`() {
        assertMacroExpansion(
            """
            let greeting = #Interned("hello", strategy: unknown)
            """,
            expandedSource: """
                let greeting = #Interned("hello", strategy: unknown)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#Interned supports only .standard and .layered strategies", line: 1, column: 16)
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on non-literal array element`() {
        assertMacroExpansion(
            """
            let value = "hello"
            let greetings = #Interned(["first", value])
            """,
            expandedSource: """
                let value = "hello"
                let greetings = #Interned(["first", value])
                """,
            diagnostics: [
                DiagnosticSpec(message: "#Interned array elements must all be string literals", line: 2, column: 17)
            ],
            macros: testMacros
        )
    }

    @Test
    func `error on invalid strategy for inlined backend`() {
        assertMacroExpansion(
            """
            let greeting = #InlinedInterned("hello", strategy: unknown)
            """,
            expandedSource: """
                let greeting = #InlinedInterned("hello", strategy: unknown)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#InlinedInterned supports only .standard and .layered strategies", line: 1, column: 16)
            ],
            macros: testMacros
        )
    }
}

// MARK: - Test Helper

private func assertMacroExpansion(
    _ originalSource: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    macros: [String: Macro.Type],
    indentationWidth: Trivia = .spaces(4),
    file: StaticString = #filePath,
    line: UInt = #line
) {
    SwiftSyntaxMacrosTestSupport.assertMacroExpansion(
        originalSource,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macros: macros,
        indentationWidth: indentationWidth,
        file: file,
        line: line
    )
}

// MARK: - Test Obfuscator

enum TestObfuscator {
    static func obfuscate(string: String, key: UInt64) -> [UInt8] {
        let bytes = Array(string.utf8)
        let n = bytes.count

        guard n > 0 else { return [] }

        var shuffleGen = SplitMix64(seed: key ^ 0xA5A5_A5A5_A5A5_A5A5)
        var permutation = Array(0 ..< n)

        for i in stride(from: n - 1, through: 1, by: -1) {
            let j = Int(shuffleGen.next() % UInt64(i + 1))
            permutation.swapAt(i, j)
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
