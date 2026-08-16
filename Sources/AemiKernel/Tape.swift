// A generic preorder-tape slot kernel: the bit-packing every AD* family tape parser shares, so the
// layout is defined and tested ONCE rather than re-derived per format. A tape is a flat `[UInt64]`
// preorder flattening of a document/tree — one slot per node, no per-node heap allocation — where
// container nodes record the tape index *after* their whole subtree for O(1) skip.
//
// Slot layout (64 bits):
//   bits 60..63  tag   (4 bits)  — caller-defined node kind
//   bits 32..59  aux   (28 bits) — caller-defined (e.g. (length << k) | flags, or element count)
//   bits  0..31  low   (32 bits) — a byte offset into the source, or a next-sibling tape index
//
// Offsets are capped at 4 GiB (the 32-bit `low`); `aux` at 2^28-1. Callers needing those bounds
// enforced reject oversized inputs at build time (as ADJSON's `TapeBuilder` does).
//
// This is the kernel ADJSON's `Slot` (value tape) and ADHTML's `HTMLTape` (DOM tape) both build on:
// ADJSON's `scalar(tag, offset, length, flags)` is `make(tag:, aux: (length << 2) | flags, low: offset)`
// and its `container(tag, count, next)` is `make(tag:, aux: count, low: next)`. Promoted here (RFC: AD*
// foundation mutualization) so a single definition serves every tape in the family.
public enum TapeSlot {
    /// Mask for the 28-bit `aux` field.
    public static let auxMask: UInt64 = 0x0FFF_FFFF
    /// Mask for the 32-bit `low` field.
    public static let lowMask: UInt64 = 0xFFFF_FFFF
    /// Largest representable `low` (byte offset / tape index): 4 GiB − 1.
    public static let maxLow = 0xFFFF_FFFF
    /// Largest representable `aux` payload: 2^28 − 1.
    public static let maxAux = 0x0FFF_FFFF

    /// Pack a slot. `tag` uses the low 4 bits; `aux` is masked to 28 bits; `low` is truncated to 32 bits.
    @inlinable @inline(__always)
    public static func make(tag: UInt8, aux: UInt64, low: Int) -> UInt64 {
        (UInt64(tag) << 60) | ((aux & auxMask) << 32) | UInt64(UInt32(truncatingIfNeeded: low))
    }

    /// The 4-bit node kind.
    @inlinable @inline(__always) public static func tag(_ s: UInt64) -> UInt8 { UInt8(s >> 60) }
    /// The 28-bit caller-defined payload.
    @inlinable @inline(__always) public static func aux(_ s: UInt64) -> UInt64 { (s >> 32) & auxMask }
    /// The 32-bit byte offset / tape index.
    @inlinable @inline(__always) public static func low(_ s: UInt64) -> Int { Int(s & lowMask) }

    /// Index of the slot immediately after the node at `node`, given its slot `s`: containers store
    /// their post-subtree index in `low` (O(1) skip); leaves advance by one. The caller classifies
    /// container-ness (the tag set is format-specific), keeping this kernel format-agnostic.
    @inlinable @inline(__always)
    public static func next(after node: Int, _ s: UInt64, isContainer: Bool) -> Int {
        isContainer ? low(s) : node &+ 1
    }
}
