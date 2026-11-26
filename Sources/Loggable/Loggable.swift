@_exported import Foundation

#if canImport(OSLog)
    @_exported import OSLog
#else
    @_exported import Logging

    // Off Apple platforms `Logger` is swift-log's. This initializer gives it the unified-logging spelling the
    // `@Loggable` expansion uses, so the macro and its callers read the same everywhere: the label is
    // `subsystem.category` (or the category alone when there is no bundle identifier, as in most Linux binaries).
    extension Logger {
        /// A logger labelled `subsystem.category`, or `category` when `subsystem` is empty.
        public init(subsystem: String, category: String) {
            self.init(label: subsystem.isEmpty ? category : "\(subsystem).\(category)")
        }
    }
#endif

// MARK: - Macro Declaration

/// Adds a `Logger` property to the annotated type.
///
/// The generated logger uses the main bundle identifier as the subsystem
/// and the type name as the category. On Apple platforms it is `os.Logger` (unified logging);
/// elsewhere it is swift-log's `Logger`, labelled `subsystem.category`, whose output goes
/// wherever the process bootstrapped `LoggingSystem` (standard error by default).
///
/// ```swift
/// @Loggable
/// struct NetworkService {
///     func fetch() {
///         logger.info("Fetching...")
///     }
/// }
/// ```
///
/// Expands to both a `nonisolated static let logger` and a `nonisolated var logger`
/// that returns the static one. Access control matches the type.
@attached(member, names: named(logger))
public macro Loggable() =
    #externalMacro(
        module: "AemiMacros",
        type: "LoggableMacro"
    )
