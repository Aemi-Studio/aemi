import Testing

@testable import AemiLexers

/// The UTF-8 entry and the UTF-16 entries, which scan the same bytes and convert the offsets back: token kinds and the
/// characters they cover agree for every language, so the terminal's byte rope and TextKit's UTF-16 storage see one
/// lexer. Whether the scanners match the ones before the move to UTF-8 is the corpus checksums' job.
struct LexerUnitParityTests {
    private static let fixtures: [(Language, String)] = [
        (
            .swift,
            "import Foundation\n/// Doc é\nlet s = \"héllo \\(x)\" // c\n@main struct A { var n = 0x1F; let t = \"\"\"\nmulti ✓\n\"\"\" }\n"
        ),
        (
            .objectiveC,
            "#import <Foundation/Foundation.h>\n@interface Foo : NSObject @\"é\" @end /* block */ int x = 3;\n"
        ),
        (.kotlin, "fun main() { val s = \"\"\"raw ✓\"\"\"; @Inject val n = 12.5f } // 注释\n"),
        (.java, "public class A { /** doc */ String s = \"x\"; @Override void f() {} }\n"),
        (.javascript, "const t = `tmpl ${x} ✓`; // é\nlet n = 1e3; /* b */ class C {}\n"),
        (.typescript, "type T = { a: number }; const s: string = 'x'; @dec class C {}\n"),
        (.c, "#include <stdio.h>\n#define X 1\nint main(void) { return 'a' + 0x10; } // é\n"),
        (.cpp, "auto f = [](int x) -> int { return x; }; std::string s = \"ü\"; /* c */\n"),
        (.python, "def f(x):\n    \"\"\"doc é\"\"\"\n    return f'{x}' # comment ✓\n@dec\nclass C: pass\n"),
        (.shell, "#!/bin/sh\necho \"$HOME ${x} é\" # c\nfor f in *; do ls \"$f\"; done\n"),
        (.fish, "set -x PATH $PATH # é\nfunction f; echo \"$argv\"; end\n"),
        (.html, "<!DOCTYPE html><div class=\"a\" id='b'>é &amp; ✓<!-- c --><script>x</script></div>\n"),
        (.css, "/* c */ .a:hover { color: #fff; margin: 1.5em; content: \"é ✓\"; }\n@media (min-width: 1px) {}\n"),
        (.json, "{\"key\": [1, 2.5e3, true, null, \"é ✓\"], \"n\": -1}\n"),
        (.yaml, "key: value # c\nlist:\n  - 1\n  - \"é ✓\"\n  - true\nnested: {a: b}\n"),
        (.toml, "[table]\nkey = \"é ✓\" # c\nn = 1_000\nb = true\narr = [1, 2]\n")
    ]

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    /// Maps a token over one unit type onto scalar indices of `text`, so two unit types compare.
    private static func scalarRanges(_ tokens: [Token], unitsPerScalar: [Int]) -> [(TokenKind, Range<Int>)] {
        // unitsPerScalar[i] is the number of units scalar i takes; prefix sums give unit offsets.
        var offsetToScalar: [Int: Int] = [:]
        var offset = 0
        for (scalar, width) in unitsPerScalar.enumerated() {
            offsetToScalar[offset] = scalar
            offset += width
        }
        offsetToScalar[offset] = unitsPerScalar.count
        return tokens.map { token in
            (
                token.kind,
                (offsetToScalar[token.range.lowerBound] ?? -1) ..< (offsetToScalar[token.range.upperBound] ?? -1)
            )
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: fixtures.map(\.0))
    func `utf8 and utf16 scans agree on every token`(language: Language) throws {
        let text = try #require(Self.fixtures.first { $0.0 == language }?.1)
        let utf16 = SyntaxHighlighter.tokens(utf16: Array(text.utf16), language: language)
        let utf8 = SyntaxHighlighter.tokens(utf8: Array(text.utf8), language: language)
        let scalars = Array(text.unicodeScalars)
        let from16 = Self.scalarRanges(utf16, unitsPerScalar: scalars.map { $0.utf16.count })
        let from8 = Self.scalarRanges(utf8, unitsPerScalar: scalars.map { $0.utf8.count })
        #expect(from16.map(\.0) == from8.map(\.0))
        #expect(from16.map(\.1) == from8.map(\.1))
        #expect(!from16.isEmpty)
        #expect(
            from16.allSatisfy { $0.1.lowerBound >= 0 && $0.1.upperBound >= 0 }, "a token boundary fell inside a scalar")
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the string entry point is the utf16 scan`() {
        let text = "let x = \"é\" // c"
        #expect(
            SyntaxHighlighter.tokens(in: text, language: .swift)
                == SyntaxHighlighter.tokens(utf16: Array(text.utf16), language: .swift))
    }
}
