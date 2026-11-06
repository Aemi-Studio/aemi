import AemiLexers
import AemiTestKit

/// Generated sources for the scanners' corpus tests: fragments of each language drawn by a seeded generator, so a
/// corpus is the same on every run and every machine. The fragments cover every token kind the scanners emit, with
/// non-ASCII text, escapes, nested and multi-line constructs, and CRLF line ends; none opens a construct it does not
/// close, so a fragment never swallows the rest of its corpus.
enum LexerCorpus {
    /// `count` fragments of `language` in a seeded order.
    static func text(_ language: Language, fragments count: Int = 2_000, seed: UInt64 = 0x3E) -> String {
        let pieces = fragments[language] ?? []
        guard !pieces.isEmpty else { return "" }
        var generator = SeededRNG(seed: seed)
        var text = ""
        for _ in 0 ..< count { text += generator.pick(pieces) }
        return text
    }

    private static let fragments: [Language: [String]] = [
        .swift: swift, .json: json, .yaml: yaml, .toml: toml, .html: html, .css: css, .objectiveC: objectiveC,
        .kotlin: kotlin, .java: java, .javascript: javascript, .typescript: typescript, .c: c, .cpp: cpp,
        .python: python, .shell: shell, .fish: fish, .rust: rust, .go: go, .ruby: ruby, .lua: lua, .tla: tla,
        .lean: lean
    ]

    private static let swift = [
        "import Foundation\n",
        "/// Returns the value at `index` — or nil, é ✓ 🙂.\n",
        "// MARK: - Section\n",
        "@MainActor public final class Store<Element: Sendable>: ObservableObject {\n",
        "    private(set) var items: [String: Int] = [\"a\": 1, \"clé\": 0x1F, \"b\": 1_000]\n",
        "    let pi = 3.141_59e-2, hex = 0xFF_FF, bin = 0b1010, octal = 0o17, range = 0..<10\n",
        "    func load(_ id: Int) async throws -> Element? { guard id > 0 else { return nil }\n",
        "        let label = \"Item \\(id) of \\(items.count) — \\\"quoted\\\" \\\\ \"\n",
        "    /* block /* nested */ still a comment */ var x = 1\n",
        "    let multi = \"\"\"\n        line one \\(x) \"quoted\"\n        \"\"\"\n",
        "#if DEBUG\nlet selector = #selector(tap) // #available(macOS 26, *)\n#endif\n",
        "    case .some(let value) where value >= 0: fallthrough\n",
        "let closure = { $0 + $1 } // shorthand arguments\n",
        "let `class` = Self.self; let café = \"naïve\"; let 変数 = 42\n",
        "let unterminated = \"no closing quote\n",
        "extension Array where Element == Int { mutating func sum() -> Int { reduce(0, +) } }\n",
        "@available(*, deprecated, message: \"use g\") nonisolated func g() -> some View { EmptyView() }\n",
        "x /= 2; y = a / b / c; let ratio = 1.5e3 / 2.0\n",
        "let path = \"C:\\\\dir\\\\file\" + \"\\u{1F600}\" + \"\\t\"\n",
        "/** A documentation block with * stars ✓ */\n",
        "struct Point: Hashable { var x, y: Double }\r\n",
        "\tlet tabbed = [1, 2, 3].map { $0 * 2 }\r\n",
        "enum Mode: String, CaseIterable { case fast = \"f\", slow }\n",
        "let e\u{301}te\u{301} = \"combining\" // U+0301 accents\n",
        "let mixed = \"\u{202E}abc\u{202C}\" // bidi controls\n",
        "actor Counter { var value = 0; func increment() { value += 1 } }\n",
        "let opt = dict[\"key\"] ?? -1; let neg = -0.5; let big = 1_000_000\n",
        "typealias Handler = @Sendable (Result<Data, any Error>) -> Void\n",
        "@objc dynamic var observed = false // Objective-C interop\n",
        "if #available(macOS 26, *) { print(\"new\") } else { print(\"old\") }\n",
        "let dollars = \"$HOME\" + \"@handle\" + \"#hash\"\n"
    ]

    private static let json = [
        "{\"name\": \"café\", \"count\": 12, \"ratio\": -0.5e-3, \"ok\": true, \"none\": null},\n",
        "[1, 2.5, -3, 4e10, \"a\\\"b\", \"\\u00e9\", false],\n",
        "{\"nested\": {\"deep\": [{\"k\": \"v\"}, []], \"emoji\": \"🙂\"}},\n",
        "  \"key with spaces\" : \"value\" ,\n",
        "\"unterminated\n",
        "{ \"a\":1,\"b\":[true,false,null] }\r\n",
        "\t\"tabbed\": \"text\", \"url\": \"https://example.com/a#b\",\n",
        "{\"数\": 42, \"é\": \"ü\", \"escaped\\\\\": \"\\\\\"}\n",
        "-12, 0, 1.0, 1E5, 3.25e+2, true, NaN, Infinity\n",
        "// not a comment in JSON\n",
        "\"back\\\\slash\": \"q\\\"uote\"\n"
    ]

    private static let yaml = [
        "---\n",
        "# a comment with é and ✓\n",
        "name: app # trailing comment\n",
        "list:\n  - 1\n  - \"two\"\n  - 'three'\n  - yes\n  - null\n",
        "anchors: &base\n  key: value\n",
        "merged: *base\n",
        "tagged: !custom value\n",
        "flow: {a: 1, b: [x, y], c: 'z'}\n",
        "key with spaces: value\n",
        "- key in a list: 3.5\n",
        "date: 2026-09-24T08:00:00Z\n",
        "block: |\n  line one\n  line two\n",
        "...\n",
        "url: http://example.com/#fragment\n",
        "TRUE: FALSE\n",
        "on: off\r\n",
        "\tindented: -12\n",
        "'single': \"double \\\" escaped\"\n",
        "  - &anchor [1, 2, 3]\n",
        "version: 1.2.3\n",
        "empty:\n",
        "quoted key: 'it''s'\n",
        "  ---not a marker\n",
        "clé: 值 # non-ASCII\n"
    ]

    private static let toml = [
        "[server]\n",
        "host = \"example.com\" # trailing comment é\n",
        "port = 8080\n",
        "[[items]]\n",
        "date = 1979-05-27T07:32:00Z\n",
        "ok = true\r\n",
        "  [indented.table]\n",
        "path = 'C:\\\\no\\\\escapes'\n",
        "multi = \"\"\"\nline one\nline \"two\"\n\"\"\"\n",
        "literal = '''raw\ntext'''\n",
        "array = [1, 2.5, -3, \"x\", [nested]]\n",
        "inline = { a = 1, b.c = \"d\" }\n",
        "dotted.key = inf\n",
        "# a comment line\n"
    ]

    private static let objectiveC = [
        "#import <Foundation/Foundation.h>\n",
        "@interface Store : NSObject @property (nonatomic) NSInteger count; @end\n",
        "NSString *name = @\"café ✓\"; char c = 'x'; BOOL ok = YES;\n",
        "/* block */ static const CGFloat ratio = 1.5f; // line comment\n",
        "#define MAX(a, b) ((a) > (b) ? (a) : (b))\n",
        "- (instancetype)init { self = [super init]; return self; }\n",
        "@implementation Store @synthesize count = _count; @end\n"
    ]

    private static let kotlin = [
        "package com.example.app\n",
        "@Composable fun Greeting(name: String): Unit { println(\"Hi $name ✓\") }\n",
        "val raw = \"\"\"\n    multi \"quoted\" line\n\"\"\"\n",
        "/* outer /* nested */ still */ var count = 0x1F + 1.5f\n",
        "data class Point(val x: Double, val y: Double) // é\n",
        "when (value) { is Int -> 'c' else -> null }\n",
        "val template = \"${user.name} has $count items\"\n"
    ]

    private static let java = [
        "package com.example;\n",
        "@Override public String toString() { return \"Point(\" + x + \")\"; }\n",
        "/** Javadoc with é */ private static final int MAX = 0x7FFF_FFFF;\n",
        "char c = '\\n'; long big = 1_000L; double d = 1.5e-3;\n",
        "String block = \"\"\"\n    text \"block\"\n    \"\"\";\n",
        "public sealed interface Shape permits Circle, Square {} // line\n",
        "var list = new ArrayList<String>(); if (list.isEmpty()) throw new IllegalStateException();\n"
    ]

    private static let javascript = [
        "import { render } from './render.js';\n",
        "const greet = (name) => `Hello ${name} ✓\nsecond line`;\n",
        "/* block */ let count = 0x1F + 1e3; // comment é\n",
        "@decorator class Store { static #secret = 'x'; get value() { return this.#secret; } }\n",
        "export default async function load() { await fetch(\"/api?q=1\"); }\n",
        "const re = /ab+c/g; const s = \"a\\\"b\";\n",
        "if (a < b && c !== undefined) { yield* items; }\n"
    ]

    private static let typescript = [
        "interface User { readonly id: number; name?: string }\n",
        "type Pair<T> = [T, T]; const pair: Pair<string> = ['a', 'b'];\n",
        "export abstract class Repo<T> implements Store<T> { private items: T[] = []; }\n",
        "@Injectable() export class Service { constructor(private http: HttpClient) {} }\n",
        "let value = input as unknown as number; // cast é\n",
        "const tpl = `total: ${sum.toFixed(2)} ✓`; /* done */\n",
        "enum Color { Red = 0xFF0000, Green = 0x00FF00 }\n"
    ]

    private static let c = [
        "#include <stdio.h>\n",
        "#define SQUARE(x) ((x) * (x))\n",
        "int main(int argc, char **argv) { printf(\"%d é\\n\", argc); return 0; }\n",
        "static const unsigned long mask = 0xFFUL; char c = '\\'';\n",
        "/* multi\n   line comment */ typedef struct Node { struct Node *next; } Node;\n",
        "float f = 1.5e-3f; // trailing comment\n",
        "#if defined(DEBUG) && DEBUG > 1\n#endif\n"
    ]

    private static let cpp = [
        "#include <vector>\n",
        "namespace app { template <typename T> class Box { T value; }; }\n",
        "auto lambda = [&](int x) -> int { return x * 2; }; // lambda\n",
        "std::string s = \"text ✓\"; char c = 'c'; constexpr double pi = 3.14159;\n",
        "class Derived final : public Base { public: void run() override; };\n",
        "/* block */ static_assert(sizeof(int) == 4, \"int size\");\n",
        "nullptr_t none = nullptr; co_await task;\n"
    ]

    private static let python = [
        "import os\n",
        "def greet(name: str) -> str:\n    return f\"Hello {name} ✓\"  # comment\n",
        "\"\"\"Module docstring with é\nand a second line.\"\"\"\n",
        "'''single-quoted\ndocstring'''\n",
        "@dataclass\nclass Point:\n    x: float = 0.5\n    y: float = 1e3\n",
        "value = None if count > 0x10 else True\n",
        "async def load(): await asyncio.sleep(0)\n",
        "path = 'C:\\\\dir' + \"it's\"\n"
    ]

    private static let shell = [
        "#!/bin/sh\n",
        "echo \"$HOME ${USER:-nobody} é\" # comment\n",
        "for file in *.swift; do wc -l \"$file\"; done\n",
        "if [ -z \"$1\" ]; then exit 1; fi\n",
        "export PATH=\"$PATH:/usr/local/bin\"; readonly NAME='value'\n",
        "case \"$1\" in start) run ;; *) usage ;; esac\n",
        "count=$((count + 1)) ${unclosed\n"
    ]

    private static let fish = [
        "set -x PATH $PATH /usr/local/bin # comment é\n",
        "function greet; echo \"hi $argv\"; end\n",
        "if test -n \"$name\"; and status is-interactive; echo 'ok'; end\n",
        "for file in *.fish; source $file; end\n",
        "switch $argv[1]; case start; run; case '*'; usage; end\n",
        "set count (math $count + 1)\n"
    ]

    private static let rust = [
        "use std::collections::HashMap;\n",
        "fn main() { let mut map: HashMap<String, i32> = HashMap::new(); }\n",
        "/* outer /* nested */ still */ let x = 0x1F_u32 + 1.5e3 as u32;\n",
        "#[derive(Debug, Clone)] pub struct Point { x: f64, y: f64 } // é\n",
        "impl Display for Point { fn fmt(&self, f: &mut Formatter) -> Result { write!(f, \"({})\", self.x) } }\n",
        "let c = 'c'; let s = \"text ✓\\n\";\n",
        "match value { Some(v) if v > 0 => v, _ => 0 }\n"
    ]

    private static let go = [
        "package main\n",
        "import \"fmt\"\n",
        "func main() { fmt.Println(\"hello ✓\") } // comment\n",
        "var raw = `multi\nline raw string`\n",
        "/* block */ type Point struct { X, Y float64 }\n",
        "for i := 0; i < len(items); i++ { defer close(ch) }\n",
        "r := 'x'; n := 0x1F + 1e3\n"
    ]

    private static let ruby = [
        "require 'json'\n",
        "def greet(name) puts \"Hello #{name} ✓\" end # comment\n",
        "=begin\nblock comment é\n=end\n",
        "class Store < Base; attr_accessor :items; end\n",
        "$global = 1; @instance = nil; value = 0x1F\n",
        "items.each do |item| yield item unless item.nil? end\n",
        "if defined?(Rails) then puts 'rails' end\n"
    ]

    private static let tla = [
        "---- MODULE Tables ----\n",
        "EXTENDS Naturals, Sequences \\* a comment é\n",
        "(* a block (* nested *) comment\nover two lines *) VARIABLES tables, keys\n",
        "Init == /\\ tables = {} /\\ keys = << >>\n",
        "Next == \\E k \\in Keys : IF k \\notin keys THEN keys' = Append(keys, k) ELSE UNCHANGED keys\n",
        "Name == \"a \\\"quoted\\\" name\" Spec == Init /\\ [][Next]_<<keys>> /\\ WF_keys(Next)\n",
        "THEOREM Spec => []TypeOK  \\* 42 and 0x1F\n"
    ]

    private static let lean = [
        "import Mathlib.Data.Nat.Basic -- a comment é\n",
        "/-- A doc comment\nover two lines. -/ def double (n : Nat) : Nat := 2 * n\n",
        "/- a block /- nested -/ comment -/ theorem two (h' : a = b) : b = a := by simp [h']\n",
        "@[simp] theorem double_zero : double 0 = 0 := rfl\n",
        "structure Point where x : Float := 1.5 deriving Repr\n",
        "def greet (name : String) : String := s!\"hi {name} \\\"x\\\"\"\n",
        "instance : Inhabited Point := ⟨{ x := 0 }⟩\n"
    ]

    private static let lua = [
        "local count = 0 -- comment é\n",
        "--[[ block\ncomment ]] local x = 1\n",
        "function greet(name) print(\"hi \" .. name) end\n",
        "for i, v in ipairs(items) do if v ~= nil then return v end end\n",
        "local t = setmetatable({}, { __index = function(t, k) return 'x' end })\n",
        "while x < 0x10 do x = x + 1.5 end\n"
    ]

    private static let html = [
        "<!DOCTYPE html>\n",
        "<html lang=\"fr\"><head><meta charset=\"utf-8\"><title>Café ✓</title></head>\n",
        "<div class=\"card\" id='main' data-x=1>text &amp; more &#169; &#x1F600;</div>\n",
        "<!-- a comment with <tags> and é -->\n",
        "<script type=\"module\">if (a < b && c > d) { go(\"</div>\"); }</script>\n",
        "<STYLE>.a { color: red; }</STYLE>\n",
        "<img src=\"a.png\" alt=\"🙂\"/><br/>\n",
        "<svg:rect x=\"1\" y=\"2\" />\n",
        "<p>unclosed &entity and &toolongentityname; and a < b</p>\r\n",
        "<!ENTITY example \"x\">\n",
        "</closing-tag>\n",
        "<a href='https://example.com/?q=1&amp;r=2'>link</a>\n",
        "<Custom-Element some:attr=\"v\">é</Custom-Element>\n"
    ]

    private static let css = [
        "/* a comment with é ✓ */\n",
        ".card, #main > .item:hover { color: #fff; margin: -1.5em 0 2px; }\n",
        "@media (min-width: 640px) { .grid { display: grid; gap: 10%; } }\n",
        "a::before { content: \"→ \\\"quoted\\\"\"; font-family: 'Helvetica Neue'; }\n",
        "#abc { background: #aabbccdd; border-color: #12345; }\n",
        ".btn { width: calc(100% - 2rem) !important; transition: all .3s; }\n",
        "// line comment in a superset\n",
        "@import url(\"theme.css\");\n",
        "  --custom-prop: 4px;\n",
        ":root { --gap: 8px; } .x { padding: var(--gap); }\r\n",
        ".é-class { z-index: -1; opacity: 0.5; }\n",
        "@font-face { font-family: X; src: url(x.woff2) format(\"woff2\"); }\n"
    ]
}
