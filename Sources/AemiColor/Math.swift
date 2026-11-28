#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#elseif canImport(Musl)
    internal import Musl
#endif

/// `x` to the power `y`, from the platform's C library (the module is otherwise the standard library only).
@inline(__always)
func power(_ x: Double, _ y: Double) -> Double {
    pow(x, y)
}
