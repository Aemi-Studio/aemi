import SwiftSyntax
import SwiftSyntaxMacros

/// Expands attached and expression string-obfuscation macros after validating their literal input.
public struct InternedMacro: AccessorMacro, ExpressionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let binding = try validatedBinding(from: declaration, attribute: node)
        let value = try propertyLiteralValue(from: node, binding: binding)
        let generated = InternedObfuscation.make(for: value, strategy: .standard, backend: .shared)

        let getter: AccessorDeclSyntax =
            """
            get {
                \(raw: generated.expressionSource)
            }
            """

        return [getter]
    }

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let input = try expressionInput(from: node, backend: backend(for: node))
        let expression: ExprSyntax = "\(raw: input.expressionSource)"
        return expression
    }
}
