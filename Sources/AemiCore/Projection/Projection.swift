

/// The common surface of the read (``Snapshot``) and write (``Mutable``)
/// projections. Refinements shared by both live in extensions of this
/// protocol.
public protocol Projection<Model> {
    associatedtype Model
    var wrappedValue: Model { get }
}

extension Projection where Model: Identifiable {
    /// Wrap path: an `Identifiable` model's raw id, re-exposed as
    /// `Identifier<Model, Model.ID>` so ids of different entities stop
    /// being interchangeable.
    ///
    /// Deliberately a protocol-extension member: it serves as the
    /// `Identifiable` witness, while the pass-through overloads on the
    /// concrete projection types outrank it at concrete call sites.
    @inlinable
    public var id: Identifier<Model, Model.ID> {
        Identifier(wrappedValue.id)
    }
}

extension Projection where Self: AnyObject & Identifiable, Model: Identifiable {
    /// Class projections (``Mutable``) additionally compete with
    /// `Identifiable`'s built-in `ObjectIdentifier` default for `AnyObject`;
    /// this strictly-more-constrained overload outranks both it and the
    /// general overload above.
    public var id: Identifier<Model, Model.ID> {
        Identifier(wrappedValue.id)
    }
}
