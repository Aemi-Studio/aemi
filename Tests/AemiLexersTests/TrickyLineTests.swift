import Testing

@testable import AemiLexers

/// A few hard lines a language, each with every token it gives, as `kind=text`: raw and nested strings, exponents,
/// attributes, comments that look like something else. Each line is checked twice: scanned as a whole text, and a line
/// at a time from the states the line lexer carries, which must agree.
struct TrickyLineTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let language: Language
        let text: String
        let tokens: [String]

        init(_ language: Language, _ text: String, _ tokens: [String]) {
            self.language = language
            self.text = text
            self.tokens = tokens
        }

        var testDescription: String { "\(language): \(text.debugDescription)" }
    }

    static let cases: [Case] = [
        Case(
            .swift,
            ##"let s = #"a "quoted" \#(x)"# // done"##,
            ["keyword=let", ##"string=#"a "quoted" \#(x)"#"##, "comment=// done"]
        ),
        Case(.swift, "let n = 1_000.5e-3 + 6.02E+23", ["keyword=let", "number=1_000.5e-3", "number=6.02E+23"]),
        Case(.swift, "let h = 0x1.8p-3", ["keyword=let", "number=0x1.8p-3"]),
        Case(
            .swift,
            "@MainActor func f() async throws -> Int { 0x1F }",
            [
                "attribute=@MainActor", "keyword=func", "keyword=async", "keyword=throws", "type=Int", "number=0x1F"
            ]
        ),
        Case(.swift, "\"\"\"\nline \"two\"\n\"\"\"", ["string=\"\"\"\nline \"two\"\n\"\"\""]),
        Case(.c, "x = 0x1e-3;", ["number=0x1e", "number=3"]),
        Case(.c, "#include <stdio.h>", ["attribute=#include"]),
        Case(.java, "double d = 1e+9 - 2e-9;", ["keyword=double", "number=1e+9", "number=2e-9"]),
        Case(
            .java,
            "@Override public String toString() { return \"x\" + 1.0f; }",
            ["attribute=@Override", "keyword=public", "type=String", "keyword=return", "string=\"x\"", "number=1.0f"]
        ),
        Case(.python, "def f(a: int = 0b101) -> None: ...", ["keyword=def", "number=0b101", "keyword=None"]),
        Case(
            .python,
            "'''a\nb''' if True else None",
            ["string='''a\nb'''", "keyword=if", "keyword=True", "keyword=else", "keyword=None"]
        ),
        Case(
            .rust,
            ##"let s = r#"raw "x""#; let c = 'a';"##,
            ["keyword=let", ##"string=r#"raw "x""#"##, "keyword=let"]
        ),
        Case(
            .rust,
            #"let p = r"C:\dir\"; let b = br"x";"#,
            ["keyword=let", #"string=r"C:\dir\""#, "keyword=let", #"string=br"x""#]
        ),
        Case(.rust, "let r = 1; let r#type = 2;", ["keyword=let", "number=1", "keyword=let", "number=2"]),
        Case(.rust, "let s = r##\"a\n\"# b\n\"##;", ["keyword=let", "string=r##\"a\n\"# b\n\"##"]),
        Case(
            .rust,
            "/* outer /* nested */ still */ let x = 1u8;",
            ["comment=/* outer /* nested */ still */", "keyword=let", "number=1u8"]
        ),
        Case(.go, "s := `raw\nline`; var x int64 = 0x7f", ["string=`raw\nline`", "keyword=var", "number=0x7f"]),
        Case(
            .kotlin,
            "val s = \"a ${b.c} $d\"; fun f() = 1L",
            ["keyword=val", "string=\"a ${b.c} $d\"", "keyword=fun", "number=1L"]
        ),
        Case(
            .objectiveC,
            "@interface Foo : NSObject @property (nonatomic) NSString *s; @end",
            [
                "attribute=@interface", "type=Foo", "type=NSObject", "attribute=@property", "type=NSString",
                "attribute=@end"
            ]
        ),
        Case(
            .ruby,
            "x = defined?(y) ? 1 : \"a #{b} c\" # c",
            ["keyword=defined?", "number=1", "string=\"a #{b} c\"", "comment=# c"]
        ),
        Case(
            .lua,
            "local s = [[long\nstring]] .. [==[a]]b]==]",
            ["keyword=local", "string=[[long\nstring]]", "string=[==[a]]b]==]"]
        ),
        Case(.lua, "f[[x]] t[i] --[[ block ]] -- line", ["string=[[x]]", "comment=--[[ block ]]", "comment=-- line"]),
        Case(
            .tla,
            "x == IF a \\in s THEN \"q\\\"r\" ELSE 12 \\* note",
            ["keyword=IF", "keyword=THEN", "string=\"q\\\"r\"", "keyword=ELSE", "number=12", "comment=\\* note"]
        ),
        Case(.tla, "(* a (* b *) c *) x' = x \\* d", ["comment=(* a (* b *) c *)", "comment=\\* d"]),
        Case(
            .lean,
            "theorem t (h' : a = b) : b = a := by simp [h'] -- c",
            ["keyword=theorem", "keyword=by", "keyword=simp", "comment=-- c"]
        ),
        Case(
            .lean,
            "/- a /- b -/ c -/ def x := \"s\" 2",
            ["comment=/- a /- b -/ c -/", "keyword=def", "string=\"s\"", "number=2"]
        ),
        Case(
            .shell,
            "echo \"$HOME ${x:-y}\" 'single' # c && ls",
            ["keyword=echo", "string=\"$HOME ${x:-y}\"", "string='single'", "comment=# c && ls"]
        ),
        Case(.fish, "set -l x (echo \"a $b\") # c", ["keyword=set", "keyword=echo", "string=\"a $b\"", "comment=# c"]),
        Case(
            .html,
            "<a href=\"x\" data-y='z'>&amp; <!-- c --> text</a>",
            [
                "tag=<a", "property=href", "string=\"x\"", "property=data-y", "string='z'", "tag=>",
                "escape=&amp;", "comment=<!-- c -->", "tag=</a", "tag=>"
            ]
        ),
        Case(
            .css,
            "@media (min-width: 10px) { .a > #b { color: #fff !important; } }",
            [
                "attribute=@media", "number=10px", "type=.a", "type=#b", "property=color", "number=#fff",
                "keyword=!important"
            ]
        ),
        Case(
            .json,
            #"{"key": [1, -2.5e3, true, null, "s\"q"], "k2": {}}"#,
            [
                #"property="key""#, "number=1", "number=-2.5e3", "keyword=true", "keyword=null", #"string="s\"q""#,
                #"property="k2""#
            ]
        ),
        Case(
            .yaml,
            "key: value # c\nlist:\n  - \"a\"\n  - 1.5\nanchor: &a *b",
            [
                "property=key", "comment=# c", "property=list", "string=\"a\"", "number=1.5",
                "property=anchor", "attribute=&a", "attribute=*b"
            ]
        ),
        Case(
            .toml,
            "[table]\nkey = \"v\" # c\n\"quoted key\" = 1979-05-27T07:32:00Z",
            [
                "tag=[table]", "property=key", "string=\"v\"", "comment=# c", "property=\"quoted key\"",
                "number=1979-05-27T07:32:00Z"
            ]
        )
    ]

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: cases)
    func `a whole-text scan gives each token`(_ tricky: Case) {
        let bytes = Array(tricky.text.utf8)
        let tokens = SyntaxHighlighter.tokens(utf8: bytes, language: tricky.language)

        #expect(tokens.map { "\($0.role)=" + String(decoding: bytes[$0.byteRange], as: UTF8.self) } == tricky.tokens)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: cases)
    func `a line scan agrees with the whole-text scan`(_ tricky: Case) {
        #expect(
            LineLexerTests.lineScan(tricky.text, language: tricky.language)
                == LineLexerTests.wholeScan(tricky.text, language: tricky.language)
        )
    }
}
