extension HighlightRole {
    /// The tree-sitter capture name the role stands for, `keyword.function` style; the segments are the hierarchy
    /// a theme falls back through.
    public var captureName: String {
        switch self {
            case .keyword: "keyword"
            case .keywordFunction: "keyword.function"
            case .keywordReturn: "keyword.return"
            case .keywordOperator: "keyword.operator"
            case .type: "type"
            case .typeBuiltin: "type.builtin"
            case .typeParameter: "type.parameter"
            case .typeDeclaration: "type.declaration"
            case .function: "function"
            case .functionMethod: "function.method"
            case .functionBuiltin: "function.builtin"
            case .functionCall: "function.call"
            case .functionMacro: "function.macro"
            case .functionSpecial: "function.special"
            case .variable: "variable"
            case .variableBuiltin: "variable.builtin"
            case .variableParameter: "variable.parameter"
            case .declarationOther: "declaration.other"
            case .string: "string"
            case .stringSpecial: "string.special"
            case .stringEscape: "string.escape"
            case .number: "number"
            case .numberFloat: "number.float"
            case .regex: "string.regex"
            case .comment: "comment"
            case .commentDocumentation: "comment.documentation"
            case .operator: "operator"
            case .punctuationBracket: "punctuation.bracket"
            case .punctuationDelimiter: "punctuation.delimiter"
            case .punctuationSpecial: "punctuation.special"
            case .attribute: "attribute"
            case .boolean: "boolean"
            case .constantBuiltin: "constant.builtin"
            case .constant: "constant"
            case .property: "property"
            case .propertyBuiltin: "property.builtin"
            case .namespace: "namespace"
            case .label: "label"
            case .tag: "tag"
            case .constructor: "constructor"
            case .embedded: "embedded"
            case .escape: "escape"
        }
    }

    /// The role a theme falls back to when it has no entry for this one: the capture name with its last segment
    /// dropped, or nil for a top-level role.
    public var parent: HighlightRole? {
        switch self {
            case .keywordFunction, .keywordReturn, .keywordOperator: .keyword
            case .typeBuiltin, .typeParameter: .type
            case .typeDeclaration: .type
            case .functionMethod, .functionBuiltin, .functionCall, .functionMacro, .functionSpecial: .function
            case .variableBuiltin, .variableParameter: .variable
            case .declarationOther: .function
            case .stringSpecial, .stringEscape, .regex: .string
            case .numberFloat: .number
            case .commentDocumentation: .comment
            case .constantBuiltin: .constant
            case .propertyBuiltin: .property
            default: nil
        }
    }
}
