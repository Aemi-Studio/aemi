extension TokenKind {
    /// The role a scanner token carries into the shared model.
    var role: HighlightRole {
        switch self {
            case .keyword: .keyword
            case .string: .string
            case .comment: .comment
            case .number: .number
            case .type: .type
            case .attribute: .attribute
            case .tag: .tag
            case .attributeName: .property
            case .entity: .escape
        }
    }
}
