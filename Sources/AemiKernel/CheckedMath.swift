/// Overflow-checked integer arithmetic that returns `nil` instead of trapping.
///
/// The engines that build on AemiKernel decode sizes, offsets, and element counts straight from
/// untrusted input — FFI payloads, parsed documents, on-disk records. A trapping overflow there
/// would abort the host process on adversarial input; returning `nil` lets the caller surface a
/// clean validation failure (`.invalidInput`, a parse error, a corrupt-page error) instead. This
/// is the **no-trap-at-boundaries** rule, and this extension is its single home — the pattern
/// previously lived inline in `ADBase/CheckedMath.swift` (apple-docs) and in ADJSON's number parser.
extension FixedWidthInteger {
    /// Returns `self + other`, or `nil` if the true sum is not representable in `Self`.
    @inlinable
    public func checkedAdding(_ other: Self) -> Self? {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? nil : value
    }

    /// Returns `self - other`, or `nil` if the true difference is not representable in `Self`.
    @inlinable
    public func checkedSubtracting(_ other: Self) -> Self? {
        let (value, overflow) = subtractingReportingOverflow(other)
        return overflow ? nil : value
    }

    /// Returns `self * other`, or `nil` if the true product is not representable in `Self`.
    @inlinable
    public func checkedMultiplied(by other: Self) -> Self? {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? nil : value
    }
}
