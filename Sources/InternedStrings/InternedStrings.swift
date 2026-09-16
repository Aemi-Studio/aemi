// MARK: - Macro Declarations

/// Curated strategies for additive freestanding obfuscation APIs.
///
/// `@Interned` remains pinned to the standard strategy for compatibility.
public enum InternedStrategy: Sendable {
    /// The current single-pass permutation + XOR keystream algorithm.
    case standard

    /// Applies the standard algorithm in two independent layers.
    ///
    /// This increases decode work slightly while making the emitted byte stream
    /// less directly attributable to a single pass.
    case layered
}

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

/// Resolves an obfuscated string literal inline.
///
/// ```swift
/// let selector = #Interned("_privateSetFrame:")
/// ```
///
/// This is additive to `@Interned` and is intended for local constants or
/// ad hoc expressions that do not warrant a stored property declaration.
@freestanding(expression)
public macro Interned(_ value: String) -> String =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an obfuscated string literal inline using a curated strategy.
@freestanding(expression)
public macro Interned(_ value: String, strategy: InternedStrategy) -> String =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an array of obfuscated string literals inline.
@freestanding(expression)
public macro Interned(_ values: [String]) -> [String] =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an array of obfuscated string literals inline using a curated strategy.
@freestanding(expression)
public macro Interned(_ values: [String], strategy: InternedStrategy) -> [String] =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an obfuscated string literal inline without routing through `SI.v`.
///
/// Use this when you want additive freestanding usage with an inlined decode path.
@freestanding(expression)
public macro InlinedInterned(_ value: String) -> String =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an obfuscated string literal inline using an additive strategy and
/// an inlined decode path.
@freestanding(expression)
public macro InlinedInterned(_ value: String, strategy: InternedStrategy) -> String =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an array of obfuscated string literals inline with an inlined decode path.
@freestanding(expression)
public macro InlinedInterned(_ values: [String]) -> [String] =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )

/// Resolves an array of obfuscated string literals inline using an additive
/// strategy and an inlined decode path.
@freestanding(expression)
public macro InlinedInterned(_ values: [String], strategy: InternedStrategy) -> [String] =
    #externalMacro(
        module: "AemiMacros",
        type: "InternedMacro"
    )
