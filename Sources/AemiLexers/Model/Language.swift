/// The languages the lexers know; anything else is plain text.
public enum Language: Sendable, Equatable, CaseIterable {
    case swift
    case objectiveC
    case kotlin
    case java
    case javascript
    case typescript
    case c
    case cpp
    case python
    case shell
    case fish
    case html
    case css
    case json
    case yaml
    case toml
    case rust
    case go
    case ruby
    case lua
    /// TLA+ and PlusCal (`\\*` and nesting `(* *)` comments).
    case tla
    /// Lean 4 (`--` and nesting `/- -/` comments).
    case lean
    case plain

    public init(fileExtension: String) {
        self = Self.byExtension[fileExtension.lowercased()] ?? .plain
    }

    /// The language of the file at `path`, decided in a fixed order: (1) the last path component, matched
    /// case-sensitively in `byFileName`; (2) the text after the last `.` of that component, as `URL.pathExtension`
    /// gives it, through ``init(fileExtension:)``, where an unmapped extension is plain; (3) for a name with no
    /// extension, the interpreter that `firstLine` names when it is a `#!` line. A leading-dot name (`.zshrc`) and a
    /// name ending in a dot (`foo.`) have no extension. A name with no language of its own, such as `Makefile` or
    /// `.env`, is plain, unless it has no extension and a shebang names one.
    ///
    /// - Parameters:
    ///   - path: The file's path; only its last component is read.
    ///   - firstLine: The file's first line, when the caller has read it. Text after the line's end is not read.
    /// - Complexity: O(length of `path` + length of `firstLine`)
    public init(path: String, firstLine: Substring? = nil) {
        self = Self.language(path: path, firstLine: firstLine)
    }

    /// File names whose language is not their extension: the shell startup files and Ruby's tooling files. Matched
    /// exactly and case-sensitively against the last path component.
    static let byFileName: [String: Language] = [
        ".zshrc": .shell, ".zprofile": .shell, ".zshenv": .shell, ".zlogin": .shell, ".zlogout": .shell,
        ".bashrc": .shell, ".bash_profile": .shell, ".bash_login": .shell, ".bash_logout": .shell,
        ".bash_aliases": .shell, ".profile": .shell,
        "Gemfile": .ruby, "Podfile": .ruby, "Rakefile": .ruby, "Fastfile": .ruby, "Brewfile": .ruby,
        "Vagrantfile": .ruby, "Guardfile": .ruby, "Capfile": .ruby
    ]

    private static func language(path: String, firstLine: Substring?) -> Language {
        let fileName = lastComponent(of: path[...])
        if let language = byFileName[String(fileName)] { return language }
        if let dot = fileName.lastIndex(of: "."), dot > fileName.startIndex,
            fileName.index(after: dot) < fileName.endIndex
        {
            return Language(fileExtension: String(fileName[fileName.index(after: dot)...]))
        }
        guard let firstLine, let language = interpreter(of: firstLine) else { return .plain }
        return language
    }

    /// The text after the last `/` of `path`, or all of `path` when it has none.
    private static func lastComponent(of path: Substring) -> Substring {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return path[path.index(after: slash)...]
    }

    /// The language of the interpreter a `#!` line names: `#!/usr/bin/python3.12` and `#!/usr/bin/env -S python3 -u`
    /// both name Python. `env` is skipped with its options and assignments, and a trailing version is dropped.
    private static func interpreter(of line: Substring) -> Language? {
        let line = line.prefix { !$0.isNewline }
        guard line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split { $0 == " " || $0 == "\t" }
        guard let first = words.first else { return nil }
        var command = lastComponent(of: first)
        if command == "env" {
            let isOption: (Substring) -> Bool = { $0.hasPrefix("-") || $0.contains("=") }
            guard let target = words.dropFirst().first(where: { !isOption($0) }) else { return nil }
            command = lastComponent(of: target)
        }
        return byInterpreter[String(withoutVersion(command))]
    }

    /// `name` without a trailing version of digits and dots: `python3.12` and `python3` both give `python`.
    private static func withoutVersion(_ name: Substring) -> Substring {
        var end = name.endIndex
        while end > name.startIndex {
            let last = name[name.index(before: end)]
            guard last == "." || ("0" ... "9").contains(last) else { break }
            end = name.index(before: end)
        }
        return name[..<end]
    }

    /// The interpreter names a `#!` line may give, mapped to their language.
    private static let byInterpreter: [String: Language] = [
        "sh": .shell, "bash": .shell, "zsh": .shell, "dash": .shell, "ksh": .shell, "fish": .fish,
        "python": .python, "ruby": .ruby, "node": .javascript, "nodejs": .javascript, "lua": .lua, "swift": .swift
    ]

    /// The language a grammar manifest or a language server names, such as `swift`, `cpp` or `bash`; nil when the
    /// name is not one the lexers know. Case-insensitive, and common aliases (`c++`, `sh`, `objc`, `js`) resolve.
    public init?(name: String) {
        guard let language = Self.byName[name.lowercased()] else { return nil }
        self = language
    }

    /// The canonical lowercase name, the one ``init(name:)`` accepts without an alias.
    public var name: String {
        switch self {
            case .swift: "swift"
            case .objectiveC: "objective-c"
            case .kotlin: "kotlin"
            case .java: "java"
            case .javascript: "javascript"
            case .typescript: "typescript"
            case .c: "c"
            case .cpp: "cpp"
            case .python: "python"
            case .shell: "shell"
            case .fish: "fish"
            case .html: "html"
            case .css: "css"
            case .json: "json"
            case .yaml: "yaml"
            case .toml: "toml"
            case .rust: "rust"
            case .go: "go"
            case .ruby: "ruby"
            case .lua: "lua"
            case .tla: "tla"
            case .lean: "lean"
            case .plain: "plain"
        }
    }

    /// The language identifier a Language Server Protocol `textDocument` carries. Matches ``name`` except where
    /// the LSP specification spells it differently.
    public var lspLanguageID: String {
        switch self {
            case .shell, .fish: "shellscript"
            case .plain: "plaintext"
            default: name
        }
    }

    private static let byName: [String: Language] = {
        var names = Dictionary(uniqueKeysWithValues: Language.allCases.map { ($0.name, $0) })
        names["objc"] = .objectiveC
        names["objective-c"] = .objectiveC
        names["objectivec"] = .objectiveC
        names["js"] = .javascript
        names["ts"] = .typescript
        names["c++"] = .cpp
        names["py"] = .python
        names["bash"] = .shell
        names["sh"] = .shell
        names["zsh"] = .shell
        names["yml"] = .yaml
        names["rs"] = .rust
        names["golang"] = .go
        names["rb"] = .ruby
        names["tla+"] = .tla
        names["tlaplus"] = .tla
        names["pluscal"] = .tla
        names["lean4"] = .lean
        names["text"] = .plain
        names["plaintext"] = .plain
        return names
    }()

    /// File extensions mapped to their language; anything else is plain text.
    public static let byExtension: [String: Language] = [
        "swift": .swift,
        "m": .objectiveC, "mm": .objectiveC, "h": .objectiveC,
        "kt": .kotlin, "kts": .kotlin,
        "java": .java,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "c": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "ipp": .cpp,
        "py": .python, "pyi": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell,
        "fish": .fish,
        "html": .html, "htm": .html, "xml": .html, "svg": .html, "plist": .html, "storyboard": .html, "xib": .html,
        "css": .css, "scss": .css, "less": .css,
        "json": .json, "jsonc": .json,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "rs": .rust,
        "go": .go,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "podspec": .ruby,
        "lua": .lua,
        "tla": .tla,
        "lean": .lean,
        "txt": .plain, "md": .plain, "markdown": .plain, "strings": .plain, "gitignore": .plain, "env": .plain
    ]
}
