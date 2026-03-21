import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Loggable (Member Macro)

public struct LoggableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let name = typeName(from: declaration) else {
            throw macroError(node, domain: "Loggable", "@Loggable can only be applied to a struct, class, actor, or enum")
        }

        let access = accessModifier(from: declaration)
        let generic = isGeneric(declaration)

        let staticLogger: DeclSyntax =
            generic
                ? """
                \(raw: access)nonisolated static var logger: Logger {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: \(literal: name))
                }
                """
                : """
                \(raw: access)nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: \(literal: name))
                """

        let instanceLogger: DeclSyntax =
            """
            \(raw: access)nonisolated var logger: Logger {
                Self.logger
            }
            """

        return [staticLogger, instanceLogger]
    }
}
