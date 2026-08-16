public import SwiftDiagnostics
public import SwiftSyntax

/// A plain ``DiagnosticMessage`` carrying a message, a domain-scoped id, and a severity.
///
/// Macro compiler plugins share this instead of each re-declaring an equivalent type.
public struct SimpleDiagnostic: DiagnosticMessage {
    public let message: String
    public let diagnosticID: MessageID
    public let severity: DiagnosticSeverity

    public init(message: String, diagnosticID: MessageID, severity: DiagnosticSeverity) {
        self.message = message
        self.diagnosticID = diagnosticID
        self.severity = severity
    }
}

/// Macro-plugin diagnostic construction — a caseless-enum namespace.
public enum MacroDiagnostics {
    /// Builds a ``Diagnostic`` anchored on `node`, in the plugin's `domain`, with a stable `id`.
    ///
    /// `domain` namespaces the diagnostic so each plugin keeps its own identifier space
    /// (e.g. `"ADJSON"`, `"ADSQLMacros.Table"`, `"URLBuilderMacros.URLQuery"`). Defaults to
    /// `.warning`, the severity macros use when they degrade gracefully rather than hard-erroring.
    public static func make(
        _ node: some SyntaxProtocol, domain: String, id: String, _ message: String,
        severity: DiagnosticSeverity = .warning
    ) -> Diagnostic {
        Diagnostic(
            node: node,
            message: SimpleDiagnostic(
                message: message, diagnosticID: MessageID(domain: domain, id: id), severity: severity))
    }
}
