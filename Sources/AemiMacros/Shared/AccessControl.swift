import SwiftSyntax

// MARK: - Access Control

/// Returns the access modifier prefix for generated members, matching the declaration's visibility.
///
/// `open` maps to `public` (generated members are not overridable).
/// `internal` (explicit or default) returns an empty string.
func accessModifier(from declaration: some DeclGroupSyntax) -> String {
    for modifier in declaration.modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.open), .keyword(.public):
            return "public "
        case .keyword(.package):
            return "package "
        case .keyword(.fileprivate):
            return "fileprivate "
        case .keyword(.private):
            return "private "
        case .keyword(.internal):
            return ""
        default:
            continue
        }
    }
    return ""
}
