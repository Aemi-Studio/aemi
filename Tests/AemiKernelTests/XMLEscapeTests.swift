import AemiKernel
import Testing

struct XMLEscapeTests {
    @Test func safeSetIsCopiedVerbatim() {
        // Inputs with no metacharacter must round-trip byte-identically (the consolidation gate).
        for s in ["", "UIView", "San Francisco", "a-b_c.d/e:f", "weight=700"] {
            #expect(XMLEscape.escaped(s) == s)
        }
    }

    @Test func escapesTheFivePredefinedEntities() {
        // & < > " ' → the XML 1.0 predefined entities (apostrophe is &apos;, not &#39;).
        #expect(XMLEscape.escaped("&") == "&amp;")
        #expect(XMLEscape.escaped("<") == "&lt;")
        #expect(XMLEscape.escaped(">") == "&gt;")
        #expect(XMLEscape.escaped("\"") == "&quot;")
        #expect(XMLEscape.escaped("'") == "&apos;")
    }

    @Test func escapesMixedTextInPlace() {
        #expect(XMLEscape.escaped("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&apos;")
        // Raw text is escaped once: an `&` in already-entity-looking text is re-escaped (correct).
        #expect(XMLEscape.escaped("&lt;") == "&amp;lt;")
        #expect(XMLEscape.escaped("Tom & Jerry's <tag>") == "Tom &amp; Jerry&apos;s &lt;tag&gt;")
    }

    @Test func preservesMultibyteUTF8() {
        // The metacharacters are ASCII; multi-byte scalars (all bytes >= 0x80) pass through intact.
        #expect(XMLEscape.escaped("caf\u{00E9} <\u{2713}>") == "caf\u{00E9} &lt;\u{2713}&gt;")
        #expect(XMLEscape.escape("\u{2713}") == Array("\u{2713}".utf8))  // bytes form, no change
    }

    @Test func bytesAndStringFormsAgree() {
        let s = "x<y>&z\"w'"
        #expect(XMLEscape.escape(s) == Array(XMLEscape.escaped(s).utf8))
    }
}
