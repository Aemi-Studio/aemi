
public import Observation

/// The observable write-side counterpart of ``Snapshot``: edits stay in a
/// buffered working copy and reach the outside world only through
/// `update()`.
///
/// As a class it composes with `@Bindable`: `$part.name` chains dynamic
/// member lookup into the `WritableKeyPath` subscript. A sheet holds the
/// buffer directly via `.sheet(item:)`, which avoids the force-unwrap race
/// of bindings into optional state.
///
/// View ownership: `@State private var draft = Mutable(part)` — created
/// once (macro-lazy), bound via `$draft.field`, one buffer per structural
/// identity (re-seed with `.id(_:)`).
@Observable
@dynamicMemberLookup
public final class Mutable<Model> {
    /// The read-side counterpart of this projection.
    public typealias Snapshot = AemiCore.Snapshot<Model>

    /// The buffered working copy of the core model.
    public private(set) var wrappedValue: Model
    private let original: Model

    public init(_ snapshot: Snapshot) {
        self.wrappedValue = snapshot.wrappedValue
        self.original = snapshot.wrappedValue
    }

    public init(_ wrappedValue: Model) {
        self.wrappedValue = wrappedValue
        self.original = wrappedValue
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Model, Value>) -> Value {
        get { wrappedValue[keyPath: keyPath] }
        set { wrappedValue[keyPath: keyPath] = newValue }
        // Yields the field in place. With get/set only, container mutations
        // (`mutable.items.append`) would CoW-clone the field's storage on
        // every call. One clone per field remains inherent: `original`
        // shares storage until the first divergence.
        _modify { yield &wrappedValue[keyPath: keyPath] }
    }

    /// Read-only fallback so computed model properties remain reachable.
    /// - Complexity: O(1) plus the member's own cost.
    public subscript<Value>(dynamicMember keyPath: KeyPath<Model, Value>) -> Value {
        wrappedValue[keyPath: keyPath]
    }

    /// A live read projection of the buffer, so presentation properties
    /// (formatting, badges, …) stay available while editing.
    public var snapshot: Snapshot {
        Snapshot(wrappedValue)
    }

    /// The one and only point where edits leave the buffer.
    public func update() -> Snapshot {
        snapshot
    }

    /// Restores the buffer to the value it started from.
    public func revert() {
        wrappedValue = original
    }
}

extension Mutable: Projection {}

/// The wrap-path `id` witness comes from the `Projection` extension —
/// mirrors `Snapshot`'s typed identity.
extension Mutable: Identifiable where Model: Identifiable {
    public typealias ID = Identifier<Model, Model.ID>
}

/// Static shadow (pass-through path) — see the note on `Projection.id`.
extension Mutable where Model: Identifiable, Model.ID: IdentifierProtocol, Model.ID.Owner == Model {
    public var id: Model.ID {
        wrappedValue.id
    }
}

extension Mutable where Model: Equatable {
    /// Whether the buffer diverged from the value it was projected from.
    /// - Complexity: O(cost of `Model.==`) per read; called per keystroke in
    ///   editors, so keep models form-sized.
    public var hasChanges: Bool { wrappedValue != original }
}

extension Mutable: CustomStringConvertible {
    public var description: String {
        String(describing: wrappedValue)
    }
}

extension Mutable: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Mutable<\(Model.self)>(\(wrappedValue))"
    }
}

/// Decoding seeds a fresh buffer from the bare model representation.
/// Encoding is deliberately absent: edits leave the buffer only through
/// `update()`/`snapshot`.
extension Mutable: Decodable where Model: Decodable {
    public convenience init(from decoder: any Decoder) throws {
        // `Snapshot` here is the nested alias, already bound to Model.
        self.init(try Snapshot(from: decoder).wrappedValue)
    }
}
