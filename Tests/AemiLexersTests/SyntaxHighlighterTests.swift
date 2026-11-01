import Testing

@testable import AemiLexers

struct SyntaxHighlighterTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `swift scanner classifies keywords strings comments numbers types and attributes`() {
        let source = "@MainActor func run() -> Int { /* a /* nested */ b */ let x = \"hi\\\"\" // done\n return 42 }"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .swift)
        let kinds = tokens.map(\.role)
        #expect(kinds == [.attribute, .keyword, .type, .comment, .keyword, .string, .comment, .keyword, .number])
        let text = tokens.map { String(source.utf16[$0.byteRange]) }
        #expect(text[3] == "/* a /* nested */ b */")
        #expect(text[5] == "\"hi\\\"\"")
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `html scanner classifies tags attributes strings comments and entities`() {
        let source = "<!DOCTYPE html><div class=\"a\">&amp;<!-- c --><script>if (a < b) {}</script></div>"
        let kinds = SyntaxHighlighter.tokens(in: source, language: .html).map(\.role)
        #expect(
            kinds == [
                .keyword, .tag, .property, .string, .tag, .escape, .comment, .tag, .tag, .tag, .tag, .tag, .tag
            ])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: [
        (
            Language.kotlin,
            "@Composable fun Greet(name: String) { /* c */ val s = \"\"\"hi\nthere\"\"\" // x\n return 1 }",
            [HighlightRole.attribute, .keyword, .type, .type, .comment, .keyword, .string, .comment, .keyword, .number]
        ),
        (
            .java, "@Override public String name() { return \"n\" + 'c' + 0x1F; } // end",
            [.attribute, .keyword, .type, .keyword, .string, .string, .number, .comment]
        ),
        (
            .javascript, "const f = async (x) => `a ${x}\nb`; // c\nreturn null;",
            [.keyword, .keyword, .string, .comment, .keyword, .keyword]
        ),
        (
            .typescript, "interface A { readonly id: number } @dec class B {}",
            [.keyword, .type, .keyword, .keyword, .attribute, .keyword, .type]
        ),
        (
            .c, "#include <stdio.h>\nint main(void) { return 'a' + 1; } /* done */",
            [.attribute, .keyword, .keyword, .keyword, .string, .number, .comment]
        ),
        (
            .cpp, "namespace N { template<typename T> T id(T v) { return nullptr; } }",
            [.keyword, .type, .keyword, .keyword, .type, .type, .type, .keyword, .keyword]
        ),
        (
            .python, "@app.route\ndef f(self):\n    \"\"\"doc\nstring\"\"\"\n    return None  # c",
            [.attribute, .keyword, .keyword, .string, .keyword, .keyword, .comment]
        ),
        (
            .shell, "if [ -z \"$HOME\" ]; then echo ${X:-1} 'q'; fi # c",
            [.keyword, .string, .keyword, .keyword, .attribute, .string, .keyword, .comment]
        ),
        (
            .fish, "function greet; set -l n $argv[1]; echo \"hi $n\"; end",
            [.keyword, .keyword, .attribute, .number, .keyword, .string, .keyword]
        )
    ])
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func `code scanners classify each language`(language: Language, source: String, expected: [HighlightRole]) {
        #expect(SyntaxHighlighter.tokens(in: source, language: language).map(\.role) == expected)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `json scanner tells keys from values and marks literals`() {
        let kinds = SyntaxHighlighter.tokens(in: "{\"a\": [1, -2.5, true, null], \"b\": \"x\"}", language: .json)
            .map(\.role)
        #expect(kinds == [.property, .number, .number, .keyword, .keyword, .property, .string])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `yaml scanner marks documents keys anchors comments and literals`() {
        let source = "---\n# c\nname: app # trailing\nlist:\n  - &a 1\n  - *a\n  - yes\nkey with spaces: \"v\"\n"
        let kinds = SyntaxHighlighter.tokens(in: source, language: .yaml).map(\.role)
        #expect(
            kinds == [
                .keyword, .comment, .property, .comment, .property, .attribute, .number, .attribute, .keyword,
                .property, .string
            ])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `toml scanner marks tables keys strings numbers dates and literals`() {
        let source = "[server]\nhost = \"a\" # c\nport = 8080\n[[items]]\ndate = 1979-05-27T07:32:00Z\nok = true\n"
        let kinds = SyntaxHighlighter.tokens(in: source, language: .toml).map(\.role)
        #expect(
            kinds == [
                .tag, .property, .string, .comment, .property, .number, .tag, .property, .number,
                .property, .keyword
            ])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `css scanner marks selectors properties numbers colours at rules and importance`() {
        let source = "@media (min-width: 10px) { .card #id { color: #fff; margin: -1.5em !important; /* c */ } }"
        let kinds = SyntaxHighlighter.tokens(in: source, language: .css).map(\.role)
        #expect(
            kinds == [
                .attribute, .number, .type, .type, .property, .number, .property, .number, .keyword, .comment
            ])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `languages come from file extensions`() {
        #expect(Language(fileExtension: "KTS") == .kotlin)
        #expect(Language(fileExtension: "tsx") == .typescript)
        #expect(Language(fileExtension: "yml") == .yaml)
        #expect(Language(fileExtension: "unknown") == .plain)
        #expect(
            Set(Language.byExtension.keys).isSuperset(of: ["py", "sh", "fish", "toml", "json", "css", "java", "cpp"]))
    }
}

extension String.UTF16View {
    fileprivate subscript(range: Range<Int>) -> String {
        let start = index(startIndex, offsetBy: range.lowerBound)
        let end = index(startIndex, offsetBy: range.upperBound)
        return String(decoding: Array(self[start ..< end]), as: UTF16.self)
    }
}

/// The languages added for the terminal editor's manifest: comment spelling, keywords and string quoting.
struct AddedLanguageScannerTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func kinds(_ source: String, _ language: Language) -> [HighlightRole] {
        SyntaxHighlighter.tokens(utf8: Array(source.utf8), language: language).map(\.role)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `rust knows fn and nested block comments`() {
        #expect(kinds("fn main() { let x = 1; } // c", .rust) == [.keyword, .keyword, .number, .comment])
        #expect(kinds("/* a /* b */ c */ fn", .rust) == [.comment, .keyword])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `go raw strings span lines`() {
        #expect(kinds("s := `a\nb` // c", .go) == [.string, .comment])
        #expect(kinds("func f() {}", .go) == [.keyword])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `ruby comments start with a hash and variables are attributes`() {
        #expect(kinds("def f # c", .ruby) == [.keyword, .comment])
        #expect(kinds("puts $stdout", .ruby) == [.keyword, .attribute])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `lua comments are double dashes and block comments are bracketed`() {
        #expect(kinds("local x = 1 -- c", .lua) == [.keyword, .number, .comment])
        #expect(kinds("--[[ a\nb ]] return", .lua) == [.comment, .keyword])
    }
}
