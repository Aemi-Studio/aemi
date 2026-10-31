/// Semantic role of a highlighted token, independent of visual style.
/// Maps to tree-sitter capture names and LSP semantic token types.
public enum HighlightRole: UInt16, Sendable, Hashable, CaseIterable {
    case keyword = 0
    case keywordFunction
    case keywordReturn
    case keywordOperator
    case type
    case typeBuiltin
    case typeParameter
    /// A type's own name at its declaration (`struct`, `class`, `enum`, `actor`, `protocol` or `typealias`); Xcode
    /// colours this distinctly from a reference to the same type (``type``, ``typeBuiltin``).
    case typeDeclaration
    case function
    case functionMethod
    case functionBuiltin
    case functionCall
    case functionMacro
    case functionSpecial
    case variable
    case variableBuiltin
    case variableParameter
    /// A non-type declaration's own name: a function, method, initializer or parameter at its declaration, coloured
    /// distinctly from a call or a use of the same name (Xcode's `declaration.other`).
    case declarationOther
    case string
    case stringSpecial
    case stringEscape
    case number
    case numberFloat
    /// A regular expression literal, distinct from a string (Xcode's `regex`).
    case regex
    case comment
    case commentDocumentation
    case `operator`
    case punctuationBracket
    case punctuationDelimiter
    case punctuationSpecial
    case attribute
    case boolean
    case constantBuiltin
    case constant
    case property
    /// A property from another module, such as a framework's (Xcode's `identifier.variable.system` for a member).
    case propertyBuiltin
    case namespace
    case label
    case tag
    case constructor
    case embedded
    case escape
}
