import Foundation
import Testing
import AemiCore

private enum User {}
private enum Sku {}

/// A string-backed identifier reaches the `String` API through explicit
/// forwarding rather than a `Collection` conformance.
///
/// `Collection` is a Character-level protocol: it supplies `starts(with:)`,
/// `split`, and `prefix`, but not `hasPrefix`, `uppercased()`,
/// `trimmingCharacters(in:)`, `replacingOccurrences(of:with:)`, `range(of:)`,
/// or `caseInsensitiveCompare` — which are the operations a string identifier
/// actually needs. Forwarding supplies all of them and keeps the identifier out
/// of `Sequence`, so it cannot be passed where a sequence of characters is
/// expected.
@Suite("String surface")
struct StringSurfaceTests {
    private typealias UserID = Identifier<User, String>

    @Test
    func `prefix and suffix predicates forward to the raw value`() {
        let sut = UserID("alpha-042")
        #expect(sut.hasPrefix("alpha"))
        #expect(!sut.hasPrefix("beta"))
        #expect(sut.hasSuffix("042"))
        #expect(!sut.hasSuffix("999"))
        #expect(sut.hasPrefix(""))
    }

    @Test
    func `case conversion forwards to the raw value`() {
        let sut = UserID("Alpha-042")
        #expect(sut.uppercased() == "ALPHA-042")
        #expect(sut.lowercased() == "alpha-042")
        #expect(UserID("").uppercased().isEmpty)
    }

    @Test
    func `splitting a composite identifier yields its components`() {
        let sut = UserID("alpha-042-eu")
        let parts: [String] = sut.split(separator: "-").map { String($0) }
        #expect(parts == ["alpha", "042", "eu"])

        let bounded: [String] = sut.split(separator: "-", maxSplits: 1).map { String($0) }
        #expect(bounded == ["alpha", "042-eu"])

        #expect(UserID("").split(separator: "-").isEmpty)

        // Empty subsequences are dropped by default, as on String.
        let collapsed: [String] = UserID("a--b").split(separator: "-").map { String($0) }
        #expect(collapsed == ["a", "b"])

        let kept: [String] = UserID("a--b")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { String($0) }
        #expect(kept == ["a", "", "b"])
    }

    @Test
    func `bounded prefix and suffix clamp instead of trapping`() {
        let sut = UserID("alpha")
        #expect(String(sut.prefix(3)) == "alp")
        #expect(String(sut.suffix(3)) == "pha")
        #expect(String(sut.prefix(0)).isEmpty)
        // Over-long bounds clamp rather than trap.
        #expect(String(sut.prefix(99)) == "alpha")
        #expect(String(sut.suffix(99)) == "alpha")
    }

    @Test
    func `trimming and replacement forward to the raw value`() {
        #expect(UserID("  alpha  ").trimmingCharacters(in: .whitespaces) == "alpha")
        #expect(UserID("\n\talpha\n").trimmingCharacters(in: .whitespacesAndNewlines) == "alpha")
        #expect(UserID("alpha-042").replacingOccurrences(of: "-", with: "_") == "alpha_042")
        #expect(UserID("aaa").replacingOccurrences(of: "a", with: "") .isEmpty)
        #expect(UserID("alpha").replacingOccurrences(of: "z", with: "_") == "alpha")
    }

    @Test
    func `substring search reports a range only when present`() {
        let sut = UserID("alpha-042")
        #expect(sut.range(of: "042") != nil)
        #expect(sut.range(of: "999") == nil)
        let found = sut.range(of: "042")
        #expect(found.map { String(sut.rawValue[$0]) } == "042")
    }

    @Test
    func `case insensitive comparison forwards to the raw value`() {
        let sut = UserID("alpha-042")
        #expect(sut.caseInsensitiveCompare("ALPHA-042") == .orderedSame)
        #expect(sut.caseInsensitiveCompare("beta") == .orderedAscending)
        #expect(sut.caseInsensitiveCompare("AAAA") == .orderedDescending)
    }

    /// These already resolve through `@dynamicMemberLookup`, which forwards key
    /// paths. The test pins them so that a change to the subscript cannot
    /// remove them silently.
    @Test
    func `key path members stay reachable without a collection conformance`() {
        let sut = UserID("alpha-042")
        #expect(sut.count == 9)
        #expect(!sut.isEmpty)
        #expect(sut.first == "a")
        #expect(sut.last == "2")
        #expect(sut.utf8.count == 9)
        #expect(UserID("").isEmpty)
    }

    @Test
    func `forwarding preserves grapheme semantics for non ascii input`() {
        let sut = Identifier<Sku, String>("café-🇫🇷")
        #expect(sut.count == 6)
        #expect(sut.hasPrefix("café"))
        #expect(sut.uppercased() == "CAFÉ-🇫🇷")
        let parts: [String] = sut.split(separator: "-").map { String($0) }
        #expect(parts == ["café", "🇫🇷"])
    }

    @Test
    func `the identifier stays a distinct type from its raw string`() {
        let sut = UserID("alpha")
        #expect(sut != UserID("beta"))
        #expect(sut == UserID("alpha"))
        #expect(sut < UserID("beta"))
        #expect(Set([sut, UserID("alpha")]).count == 1)
    }
}
