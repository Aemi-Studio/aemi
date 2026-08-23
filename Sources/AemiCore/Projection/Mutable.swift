
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

    @ObservationIgnored private var _storage: Model
    @ObservationIgnored private let original: Model

    /// Key paths rooted in a *generic* type are instantiated by the runtime on
    /// every use, and each instantiation allocates. Letting the `@Observable`
    /// macro synthesise `wrappedValue` therefore cost 531 ns and 2 mallocs per
    /// read here, against 10 ns for the same shape on a concrete class.
    /// Hoisting the key path to a per-instance `let` brings it to 6 ns.
    ///
    /// The accessors below are the macro's own expansion verbatim, with
    /// `\.wrappedValue` replaced by this stored key path.
    @ObservationIgnored
    private let wrappedValueKeyPath: KeyPath<Mutable<Model>, Model> = \Mutable<Model>.wrappedValue

    /// The buffered working copy of the core model.
    public private(set) var wrappedValue: Model {
        get {
            access(keyPath: wrappedValueKeyPath)
            return _storage
        }
        set {
            withMutation(keyPath: wrappedValueKeyPath) { _storage = newValue }
        }
        // Yields in place so container mutations do not CoW-clone; mirrors the
        // macro's `_modify`, which the hand-written accessors above replace.
        _modify {
            access(keyPath: wrappedValueKeyPath)
            _$observationRegistrar.willSet(self, keyPath: wrappedValueKeyPath)
            defer { _$observationRegistrar.didSet(self, keyPath: wrappedValueKeyPath) }
            yield &_storage
        }
    }

    public init(_ snapshot: Snapshot) {
        self._storage = snapshot.wrappedValue
        self.original = snapshot.wrappedValue
    }

    public init(_ wrappedValue: Model) {
        self._storage = wrappedValue
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
