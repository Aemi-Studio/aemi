import InternedStrings
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import AemiMacros

private let testMacros: [String: Macro.Type] = [
    "Interned": InternedMacro.self,
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
        for i in 0..<(originalBytes.count - 3) {
            let substring = Array(originalBytes[i..<(i + 4)])
            let found = obfuscated.indices.dropLast(3).contains { j in
                Array(obfuscated[j..<(j + 4)]) == substring
            }
            #expect(!found, "Found plaintext substring at index \(i)")
        }
    }
}

// MARK: - Macro Expansion Tests

@Suite("Macro Expansion")
struct MacroExpansionTests {
    @Test("Property with argument form")
    func argumentForm() {
        assertMacroExpansion(
            """
            @Interned("hello") static var greeting: String
            """,
            expandedSource: """
            static var greeting: String {
                get {
                    SI.v([$BYTES$], $KEY$)
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Property with initializer form")
    func initializerForm() {
        assertMacroExpansion(
            """
            @Interned static var greeting = "hello"
            """,
            expandedSource: """
            static var greeting = "hello" {
                get {
                    SI.v([$BYTES$], $KEY$)
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Instance property")
    func instanceProperty() {
        assertMacroExpansion(
            """
            @Interned("value") var instance: String
            """,
            expandedSource: """
            var instance: String {
                get {
                    SI.v([$BYTES$], $KEY$)
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Let binding works")
    func letBindingWorks() {
        assertMacroExpansion(
            """
            @Interned("x") static let x: String
            """,
            expandedSource: """
            static let x: String {
                get {
                    SI.v([$BYTES$], $KEY$)
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
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
                DiagnosticSpec(message: "@Interned requires a string literal (as argument or initializer)", line: 1, column: 1)
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
                DiagnosticSpec(message: "@Interned cannot be applied to a computed property", line: 1, column: 1)
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
        var permutation = Array(0..<n)

        for i in stride(from: n - 1, through: 1, by: -1) {
            let j = Int(shuffleGen.next() % UInt64(i + 1))
            permutation.swapAt(i, j)
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
