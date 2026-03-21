import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import AemiMacros

private let testMacros: [String: Macro.Type] = [
    "Loggable": LoggableMacro.self,
]

// MARK: - Expansion Tests

@Suite("Macro Expansion")
struct MacroExpansionTests {
    @Test("Public struct")
    func publicStruct() {
        assertMacroExpansion(
            """
            @Loggable
            public struct NetworkService {
            }
            """,
            expandedSource: """
            public struct NetworkService {

                public nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "NetworkService")

                public nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Internal struct (default)")
    func internalStruct() {
        assertMacroExpansion(
            """
            @Loggable
            struct InternalService {
            }
            """,
            expandedSource: """
            struct InternalService {

                nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "InternalService")

                nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Private class")
    func privateClass() {
        assertMacroExpansion(
            """
            @Loggable
            private class PrivateHelper {
            }
            """,
            expandedSource: """
            private class PrivateHelper {

                private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "PrivateHelper")

                private nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Open class maps to public")
    func openClass() {
        assertMacroExpansion(
            """
            @Loggable
            open class BaseService {
            }
            """,
            expandedSource: """
            open class BaseService {

                public nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "BaseService")

                public nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Actor")
    func actor() {
        assertMacroExpansion(
            """
            @Loggable
            actor DataStore {
            }
            """,
            expandedSource: """
            actor DataStore {

                nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "DataStore")

                nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Public actor")
    func publicActor() {
        assertMacroExpansion(
            """
            @Loggable
            public actor PublicStore {
            }
            """,
            expandedSource: """
            public actor PublicStore {

                public nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "PublicStore")

                public nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Enum")
    func enumType() {
        assertMacroExpansion(
            """
            @Loggable
            enum Analytics {
            }
            """,
            expandedSource: """
            enum Analytics {

                nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "Analytics")

                nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Fileprivate struct")
    func fileprivateStruct() {
        assertMacroExpansion(
            """
            @Loggable
            fileprivate struct Helper {
            }
            """,
            expandedSource: """
            fileprivate struct Helper {

                fileprivate nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "Helper")

                fileprivate nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Package struct")
    func packageStruct() {
        assertMacroExpansion(
            """
            @Loggable
            package struct PackageService {
            }
            """,
            expandedSource: """
            package struct PackageService {

                package nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "PackageService")

                package nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Struct with existing members")
    func structWithMembers() {
        assertMacroExpansion(
            """
            @Loggable
            struct Service {
                var name: String
            }
            """,
            expandedSource: """
            struct Service {
                var name: String

                nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "Service")

                nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }
}

    @Test("Generic struct emits computed static var")
    func genericStruct() {
        assertMacroExpansion(
            """
            @Loggable
            struct Container<Value: Codable> {
            }
            """,
            expandedSource: """
            struct Container<Value: Codable> {

                nonisolated static var logger: Logger {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "Container")
                }

                nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

    @Test("Generic actor emits computed static var")
    func genericActor() {
        assertMacroExpansion(
            """
            @Loggable
            public actor Store<T: Sendable> {
            }
            """,
            expandedSource: """
            public actor Store<T: Sendable> {

                public nonisolated static var logger: Logger {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "Store")
                }

                public nonisolated var logger: Logger {
                    Self.logger
                }
            }
            """,
            macros: testMacros,
            indentationWidth: .spaces(4)
        )
    }

// MARK: - Diagnostic Tests

@Suite("Diagnostics")
struct DiagnosticTests {
    @Test("Error on protocol")
    func errorOnProtocol() {
        assertMacroExpansion(
            """
            @Loggable
            protocol MyProtocol {
            }
            """,
            expandedSource: """
            protocol MyProtocol {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Loggable can only be applied to a struct, class, actor, or enum", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    @Test("Error on extension")
    func errorOnExtension() {
        assertMacroExpansion(
            """
            @Loggable
            extension String {
            }
            """,
            expandedSource: """
            extension String {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Loggable can only be applied to a struct, class, actor, or enum", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }
}

// MARK: - Test Helper

private func assertMacroExpansion(
    _ originalSource: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    macros: [String: Macro.Type],
    indentationWidth: Trivia = .spaces(4),
    file: StaticString = #filePath,
    line: UInt = #line
) {
    SwiftSyntaxMacrosTestSupport.assertMacroExpansion(
        originalSource,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macros: macros,
        indentationWidth: indentationWidth,
        file: file,
        line: line
    )
}
