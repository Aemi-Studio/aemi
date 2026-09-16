import InternedStrings
import Testing

@Suite("Interned expression compatibility")
struct InternedExpressionTests {
    @Test
    func `shared expressions preserve literal values with each strategy`() {
        #expect(#Interned("Hello 世界 🌍") == "Hello 世界 🌍")
        #expect(#Interned("layered", strategy: .layered) == "layered")
        #expect(#Interned(["", "one", "emoji 👋"]) == ["", "one", "emoji 👋"])
        #expect(#Interned(["alpha", "beta"], strategy: .layered) == ["alpha", "beta"])
    }

    @Test
    func `inlined expressions preserve literal values with each strategy`() {
        #expect(#InlinedInterned("Hello 世界 🌍") == "Hello 世界 🌍")
        #expect(#InlinedInterned("layered", strategy: .layered) == "layered")
        #expect(#InlinedInterned(["", "one", "emoji 👋"]) == ["", "one", "emoji 👋"])
        #expect(#InlinedInterned(["alpha", "beta"], strategy: .layered) == ["alpha", "beta"])
    }

    @Test
    func `literal escapes have the same value as Swift string literals`() {
        #expect(#Interned("line\nquote\" slash\\ \u{1F44B}") == "line\nquote\" slash\\ \u{1F44B}")
        #expect(#InlinedInterned("tab\tend", strategy: .layered) == "tab\tend")
        #expect(#Interned(#"raw\ntext"#) == #"raw\ntext"#)
    }
}
