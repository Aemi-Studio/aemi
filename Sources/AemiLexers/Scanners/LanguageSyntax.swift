/// What a code scanner needs to know about a language: its keywords and how comments, strings, annotations
/// and preprocessor lines are spelled. Everything else (numbers, capitalized types) is common.
struct LanguageSyntax: Sendable {
    var keywords: Set<String>
    /// Sequences that start a comment running to the end of the line.
    var lineComments: [[UInt8]] = [Array("//".utf8)]
    var blockComment: (start: [UInt8], end: [UInt8])? = (Array("/*".utf8), Array("*/".utf8))
    var nestsBlockComments = false
    /// Quote units that delimit strings; a tripled quote from `tripleQuotes` spans lines.
    var quotes: Set<UInt8> = [ASCII.quote]
    var tripleQuotes: Set<UInt8> = []
    /// Quotes whose strings span lines without tripling, such as JavaScript template literals.
    var multilineQuotes: Set<UInt8> = []
    /// `#word` at the start of a directive is an attribute (C family).
    var hasPreprocessor = false
    /// `@word` is an attribute: annotations, decorators, Swift attributes, Objective-C literals.
    var hasAnnotations = false
    /// `$word` and `${…}` are attributes (shells).
    var hasVariables = false

    static func syntax(for language: Language) -> LanguageSyntax {
        switch language {
            case .swift: swift
            case .objectiveC: objectiveC
            case .kotlin: kotlin
            case .java: java
            case .javascript: javascript
            case .typescript: typescript
            case .c: c
            case .cpp: cpp
            case .python: python
            case .shell: shell
            case .fish: fish
            case .rust: rust
            case .go: go
            case .ruby: ruby
            case .lua: lua
            default: LanguageSyntax(keywords: [])
        }
    }

    static let swift = LanguageSyntax(
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
            "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
            "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
            "defer",
            "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where",
            "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
            "async", "actor", "some", "any", "consuming", "borrowing", "nonisolated", "isolated", "macro", "package",
            "lazy", "weak", "unowned", "override", "final", "mutating", "nonmutating", "indirect", "convenience",
            "required", "optional", "dynamic", "willSet", "didSet", "get", "set", "each"
        ],
        nestsBlockComments: true, tripleQuotes: [ASCII.quote], hasAnnotations: true
    )

    static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
        "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "NULL", "_Bool", "_Static_assert", "_Alignof", "_Atomic", "_Thread_local", "typeof"
    ]

    static let objectiveC = LanguageSyntax(
        keywords: cKeywords.union([
            "id", "self", "super", "nil", "Nil", "YES", "NO", "BOOL", "instancetype", "SEL", "IMP", "Class", "in",
            "out",
            "inout", "bycopy", "byref", "oneway", "nonnull", "nullable", "__weak", "__strong", "__block", "__bridge",
            "__kindof", "NS_ENUM", "NS_OPTIONS", "NSInteger", "NSUInteger", "CGFloat"
        ]),
        quotes: [ASCII.quote, ASCII.apostrophe], hasPreprocessor: true, hasAnnotations: true
    )

    static let c = LanguageSyntax(keywords: cKeywords, quotes: [ASCII.quote, ASCII.apostrophe], hasPreprocessor: true)

    static let cpp = LanguageSyntax(
        keywords: cKeywords.union([
            "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor", "catch", "char8_t", "char16_t", "char32_t",
            "class", "compl", "concept", "consteval", "constexpr", "constinit", "const_cast", "co_await", "co_return",
            "co_yield", "decltype", "delete", "dynamic_cast", "explicit", "export", "friend", "mutable", "namespace",
            "new", "noexcept", "not", "not_eq", "nullptr", "operator", "or", "or_eq", "private", "protected", "public",
            "reinterpret_cast", "requires", "static_assert", "static_cast", "template", "this", "thread_local", "throw",
            "try", "typeid", "typename", "using", "virtual", "wchar_t", "xor", "xor_eq", "override", "final"
        ]),
        quotes: [ASCII.quote, ASCII.apostrophe], hasPreprocessor: true
    )

    static let java = LanguageSyntax(
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
            "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
            "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
            "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
            "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "var",
            "record",
            "sealed", "permits", "yield", "non-sealed"
        ],
        quotes: [ASCII.quote, ASCII.apostrophe], tripleQuotes: [ASCII.quote], hasAnnotations: true
    )

    static let kotlin = LanguageSyntax(
        keywords: [
            "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is",
            "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof",
            "val",
            "var", "when", "while", "by", "catch", "constructor", "delegate", "dynamic", "field", "file", "finally",
            "get", "import", "init", "param", "property", "receiver", "set", "setparam", "value", "where", "abstract",
            "actual", "annotation", "companion", "const", "crossinline", "data", "enum", "expect", "external", "final",
            "infix", "inline", "inner", "internal", "lateinit", "noinline", "open", "operator", "out", "override",
            "private", "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg", "it"
        ],
        nestsBlockComments: true, quotes: [ASCII.quote, ASCII.apostrophe], tripleQuotes: [ASCII.quote],
        hasAnnotations: true, hasVariables: true
    )

    static let javascriptKeywords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let",
        "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
        "void", "while", "with", "yield", "async", "of", "static", "get", "set"
    ]

    static let javascript = LanguageSyntax(
        keywords: javascriptKeywords, quotes: [ASCII.quote, ASCII.apostrophe, ASCII.backtick],
        multilineQuotes: [ASCII.backtick], hasAnnotations: true
    )

    static let typescript = LanguageSyntax(
        keywords: javascriptKeywords.union([
            "abstract", "any", "as", "asserts", "bigint", "boolean", "declare", "implements", "infer", "interface",
            "is", "keyof", "module", "namespace", "never", "number", "object", "override", "private", "protected",
            "public", "readonly", "satisfies", "string", "symbol", "type", "unique", "unknown"
        ]),
        quotes: [ASCII.quote, ASCII.apostrophe, ASCII.backtick], multilineQuotes: [ASCII.backtick], hasAnnotations: true
    )

    static let python = LanguageSyntax(
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del",
            "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self"
        ],
        lineComments: [Array("#".utf8)], blockComment: nil, quotes: [ASCII.quote, ASCII.apostrophe],
        tripleQuotes: [ASCII.quote, ASCII.apostrophe], hasAnnotations: true
    )

    static let shell = LanguageSyntax(
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
            "select", "time", "local", "export", "return", "exit", "declare", "readonly", "unset", "shift", "source",
            "alias", "eval", "exec", "set", "trap", "true", "false", "break", "continue", "echo", "printf", "read",
            "test"
        ],
        lineComments: [Array("#".utf8)], blockComment: nil, quotes: [ASCII.quote, ASCII.apostrophe], hasVariables: true
    )

    static let fish = LanguageSyntax(
        keywords: [
            "if", "else", "end", "for", "in", "while", "function", "switch", "case", "begin", "and", "or", "not",
            "return", "break", "continue", "set", "source", "command", "builtin", "test", "true", "false", "echo",
            "printf", "read", "string", "math", "argparse", "status", "exit", "abbr", "alias", "block", "contains",
            "count", "functions", "type", "eval", "exec"
        ],
        lineComments: [Array("#".utf8)], blockComment: nil, quotes: [ASCII.quote, ASCII.apostrophe], hasVariables: true
    )

    static let rust = LanguageSyntax(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
            "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
            "union", "macro_rules"
        ],
        nestsBlockComments: true
    )

    static let go = LanguageSyntax(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "true", "false", "nil", "iota", "make", "new", "len", "cap", "append", "panic",
            "recover"
        ],
        quotes: [ASCII.quote, ASCII.apostrophe, ASCII.backtick], multilineQuotes: [ASCII.backtick]
    )

    static let ruby = LanguageSyntax(
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
            "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
            "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield",
            "require", "require_relative", "include", "extend", "attr_reader", "attr_writer", "attr_accessor",
            "private", "protected", "public", "raise", "lambda", "proc", "puts", "print"
        ],
        lineComments: [Array("#".utf8)], blockComment: (Array("=begin".utf8), Array("=end".utf8)),
        quotes: [ASCII.quote, ASCII.apostrophe], hasVariables: true
    )

    static let lua = LanguageSyntax(
        keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local",
            "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "self", "require", "print",
            "pairs", "ipairs", "type", "tostring", "tonumber", "setmetatable", "getmetatable", "error", "pcall"
        ],
        lineComments: [Array("--".utf8)], blockComment: (Array("--[[".utf8), Array("]]".utf8)),
        quotes: [ASCII.quote, ASCII.apostrophe]
    )
}
