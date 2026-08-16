import Testing

@testable import AemiUnicode

private func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }
private func values(_ s: [Unicode.Scalar]) -> [UInt32] { s.map(\.value) }

struct NFDTests {
    @Test func decomposesLatinPrecomposed() {
        #expect(values(NFD.decompose(scalars("é"))) == [0x65, 0x301])  // e + combining acute
        #expect(values(NFD.decompose(scalars("Å"))) == [0x41, 0x30A])  // A + ring above
    }

    @Test func asciiAndLatinBelowThresholdPassThrough() {
        #expect(values(NFD.decompose(scalars("Abc1"))) == [0x41, 0x62, 0x63, 0x31])
    }

    @Test func hangulSyllableArithmetic() {
        // 가 U+AC00 (LV): L = ᄀ U+1100, V = ᅡ U+1161, no trailing jamo.
        #expect(values(NFD.decompose(scalars("가"))) == [0x1100, 0x1161])
        // 각 U+AC01 (LVT): adds trailing ᆨ U+11A8.
        #expect(values(NFD.decompose(scalars("각"))) == [0x1100, 0x1161, 0x11A8])
    }

    @Test func canonicalReorderingByCombiningClass() {
        // a + acute (ccc 230) + dot-below (ccc 220) must reorder so the lower class comes first.
        let unordered: [Unicode.Scalar] = [
            Unicode.Scalar(0x61)!, Unicode.Scalar(0x301)!, Unicode.Scalar(0x323)!
        ]
        #expect(values(NFD.decompose(unordered)) == [0x61, 0x323, 0x301])
        // Already-canonical order is preserved (stability of equal/ascending classes).
        let ordered: [Unicode.Scalar] = [
            Unicode.Scalar(0x61)!, Unicode.Scalar(0x323)!, Unicode.Scalar(0x301)!
        ]
        #expect(values(NFD.decompose(ordered)) == [0x61, 0x323, 0x301])
    }

    @Test func decompositionIsIdempotent() {
        // ǡ U+01E1 exercises recursive (pre-expanded) decomposition; the rest cover mixed content.
        for s in ["é", "Å", "가", "각", "ǡ", "café", "Σίσυφος"] {
            let once = NFD.decompose(scalars(s))
            #expect(values(NFD.decompose(once)) == values(once))
        }
    }
}

struct CaseFoldingTests {
    @Test func lowercasesASCII() {
        #expect(values(CaseFolding.lowercase(scalars("HELLO World 123"))) == values(scalars("hello world 123")))
    }

    @Test func appliesFinalSigma() {
        // Final Σ → ς (U+03C2); medial Σ → σ (U+03C3). Stdlib lowercased() does NOT apply this rule.
        #expect(values(CaseFolding.lowercase(scalars("ΟΔΟΣ"))) == [0x3BF, 0x3B4, 0x3BF, 0x3C2])
        #expect(values(CaseFolding.lowercase(scalars("ΣΟΣ"))) == [0x3C3, 0x3BF, 0x3C2])
    }

    @Test func fullMultiScalarMappings() {
        // İ U+0130 → i + combining dot above; ẞ U+1E9E → ß.
        #expect(values(CaseFolding.lowercase([Unicode.Scalar(0x130)!])) == [0x69, 0x307])
        #expect(values(CaseFolding.lowercase([Unicode.Scalar(0x1E9E)!])) == [0xDF])
    }

    @Test func finalSigmaContextPredicate() {
        // Sigma preceded by a cased letter with nothing after ⇒ final.
        #expect(CaseFolding.isFinalSigma(scalars("ΟΣ"), at: 1))
        // Leading sigma (not preceded by a cased letter) ⇒ not final.
        #expect(!CaseFolding.isFinalSigma(scalars("ΣΟ"), at: 0))
    }
}

struct UnicodeSetsTests {
    @Test func jsWhitespaceBinarySearchBoundaries() {
        #expect(!UnicodeSets.isJsWhitespace(0x8))  // just below the first range (0x9…0xD)
        #expect(UnicodeSets.isJsWhitespace(0x9))  // lower endpoint
        #expect(UnicodeSets.isJsWhitespace(0xD))  // upper endpoint
        #expect(!UnicodeSets.isJsWhitespace(0xE))  // just above it
        #expect(UnicodeSets.isJsWhitespace(0x20))  // singleton range (space)
        #expect(!UnicodeSets.isJsWhitespace(0x21))  // in a gap
        #expect(UnicodeSets.isJsWhitespace(0x2000))  // multi-value range start
        #expect(UnicodeSets.isJsWhitespace(0x200A))  // …and end
        #expect(!UnicodeSets.isJsWhitespace(0x200B))  // just past it
    }

    @Test func predicatesClassifyRepresentativeScalars() {
        #expect(UnicodeSets.isChinese(0x4E2D))  // 中
        #expect(!UnicodeSets.isChinese(0x41))  // 'A'
        #expect(UnicodeSets.isNonspacingMark(0x301))  // combining acute accent
        #expect(!UnicodeSets.isNonspacingMark(0x41))
        #expect(UnicodeSets.isCleanTextRemoved(0x0))  // NUL control
        #expect(!UnicodeSets.isCleanTextRemoved(0x41))
    }

    @Test func boundsBailIsSafeBelowAndAbove() {
        #expect(!UnicodeSets.isChinese(0x0))  // below every CJK range
        #expect(!UnicodeSets.isChinese(0x10FFFF))  // above the assigned CJK ranges
    }

    @Test func nfdDecompositionLookup() {
        #expect(UnicodeSets.nfdDecomposition(of: 0xE9).map(Array.init) == [0x65, 0x301])  // é
        #expect(UnicodeSets.nfdDecomposition(of: 0x41) == nil)  // ASCII: decomposes to itself
        #expect(UnicodeSets.nfdDecomposition(of: 0xAC00) == nil)  // Hangul: derived arithmetically, not tabled
    }
}
