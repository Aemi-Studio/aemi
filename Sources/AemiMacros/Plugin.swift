import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct AemiPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        InternedMacro.self,
        LoggableMacro.self,
    ]
}
