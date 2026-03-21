import SwiftSyntax

// MARK: - Type Validation

/// Extracts the type name from a declaration, or returns `nil` if not a concrete type (struct/class/actor/enum).
func typeName(from declaration: some DeclGroupSyntax) -> String? {
    if let decl = declaration.as(StructDeclSyntax.self) {
        return decl.name.trimmedDescription
    } else if let decl = declaration.as(ClassDeclSyntax.self) {
        return decl.name.trimmedDescription
    } else if let decl = declaration.as(ActorDeclSyntax.self) {
        return decl.name.trimmedDescription
    } else if let decl = declaration.as(EnumDeclSyntax.self) {
        return decl.name.trimmedDescription
    }
    return nil
}

/// Returns `true` if the declaration has generic type parameters.
func isGeneric(_ declaration: some DeclGroupSyntax) -> Bool {
    if let decl = declaration.as(StructDeclSyntax.self) {
        return decl.genericParameterClause != nil
    } else if let decl = declaration.as(ClassDeclSyntax.self) {
        return decl.genericParameterClause != nil
    } else if let decl = declaration.as(ActorDeclSyntax.self) {
        return decl.genericParameterClause != nil
    } else if let decl = declaration.as(EnumDeclSyntax.self) {
        return decl.genericParameterClause != nil
    }
    return false
}
