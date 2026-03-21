// MARK: - Macro Declarations

/// Marks a property for compile-time string obfuscation.
///
/// The string value is obfuscated at compile time and decoded at runtime.
/// Each property gets its own unique key.
///
/// ```swift
/// enum Selectors {
///     @Interned static var setFrame = "_privateSetFrame:"
///     @Interned("_privateGetBounds") static var getBounds
/// }
/// ```
///
/// Value can be provided as an initializer or macro argument.
@attached(accessor)
public macro Interned(_ value: String) =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Marks a property for compile-time string obfuscation using an initializer.
@attached(accessor)
public macro Interned() =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )
