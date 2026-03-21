import SwiftDiagnostics
import SwiftSyntax

// MARK: - Shared Diagnostics

func macroError(_ node: some SyntaxProtocol, domain: String, _ message: String) -> DiagnosticsError {
    DiagnosticsError(diagnostics: [
        Diagnostic(node: Syntax(node), message: AemiDiagnostic(domain: domain, message: message))
    ])
}

struct AemiDiagnostic: DiagnosticMessage {
    let domain: String
    let message: String

    var diagnosticID: MessageID {
        MessageID(domain: domain, id: "error")
    }

    var severity: DiagnosticSeverity { .error }
}
