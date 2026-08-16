import Testing

@testable import AemiMacroSupport

@Suite struct EscapedIdentifierTests {
    @Test func backticksReservedWords() {
        #expect(SwiftSource.escapedIdentifier("default") == "`default`")
        #expect(SwiftSource.escapedIdentifier("class") == "`class`")
        #expect(SwiftSource.escapedIdentifier("Self") == "`Self`")
        #expect(SwiftSource.escapedIdentifier("Any") == "`Any`")
    }

    @Test func leavesOrdinaryNamesUnchanged() {
        #expect(SwiftSource.escapedIdentifier("name") == "name")
        #expect(SwiftSource.escapedIdentifier("userID") == "userID")
        #expect(SwiftSource.escapedIdentifier("klass") == "klass")
    }

    @Test func keywordSetCoversContextualAndDeclarationKeywords() {
        #expect(SwiftSource.keywords.contains("associatedtype"))
        #expect(SwiftSource.keywords.contains("fileprivate"))
        #expect(SwiftSource.keywords.contains("rethrows"))
        #expect(!SwiftSource.keywords.contains("foo"))
        #expect(SwiftSource.keywords.count == 52)
    }
}

@Suite struct SwiftStringLiteralTests {
    @Test func wrapsPlainTextInQuotes() {
        #expect(SwiftSource.stringLiteral("abc") == #""abc""#)
        #expect(SwiftSource.stringLiteral("") == #""""#)
    }

    @Test func escapesQuotesAndBackslashes() {
        // Input: a"b\c  →  "a\"b\\c"
        #expect(SwiftSource.stringLiteral(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func escapesWhitespaceControls() {
        #expect(SwiftSource.stringLiteral("a\nb") == #""a\nb""#)
        #expect(SwiftSource.stringLiteral("\t") == #""\t""#)
        #expect(SwiftSource.stringLiteral("\r") == #""\r""#)
    }

    @Test func escapesNulAndControlScalars() {
        #expect(SwiftSource.stringLiteral("\u{0}") == #""\0""#)
        #expect(SwiftSource.stringLiteral("\u{1}") == #""\u{01}""#)
        #expect(SwiftSource.stringLiteral("\u{1F}") == #""\u{1f}""#)
        // 0x20 (space) is the first non-control scalar — passes through.
        #expect(SwiftSource.stringLiteral("\u{20}") == #"" ""#)
    }

    @Test func leavesNonAsciiUnescaped() {
        #expect(SwiftSource.stringLiteral("café—∑") == #""café—∑""#)
    }
}
