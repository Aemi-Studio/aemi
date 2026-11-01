import AemiLexers

/// A token as the scanners build it: `role` over `range`, in the lexical layer, with no modifiers.
func lexical(_ role: HighlightRole, _ range: Range<Int>) -> HighlightToken {
    HighlightToken(byteRange: range, role: role, layer: .lexical)
}
