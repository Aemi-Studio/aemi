@_exported import Foundation
@_exported import OSLog

// MARK: - Macro Declaration

/// Adds a `Logger` property to the annotated type.
///
/// The generated logger uses the main bundle identifier as the subsystem
/// and the type name as the category.
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
