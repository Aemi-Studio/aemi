

/// An immutable, render-side projection of a model.
///
/// Key-path dynamic member lookup (SE-0252) forwards the model's members
/// visible at the use site. Feature modules add curated display properties
/// in constrained extensions (`extension Snapshot where Model == Part`),
/// including ones derived from `@_spi`-gated internals. Mutation goes
/// through ``mutable`` and returns via `update()`.
@dynamicMemberLookup
public struct Snapshot<Model> {
    /// The write-side counterpart of this projection.
    public typealias Mutable = AemiCore.Mutable<Model>

    /// The wrapped core model, for when the actual object is needed back.
    public let wrappedValue: Model

    /// Wraps the model by value; copies nothing beyond field retains.
    @inlinable
    public init(_ wrappedValue: Model) {
        self.wrappedValue = wrappedValue
    }

    /// Forwards any member of `Model` visible at the use site.
    /// - Complexity: O(1) plus the member's own cost.
    @inlinable
    public subscript<Value>(dynamicMember keyPath: KeyPath<Model, Value>) -> Value {
        wrappedValue[keyPath: keyPath]
    }

    /// The only door to mutation. Each access projects a *fresh* editing
    /// buffer seeded from this value; hold on to it for the duration of an
    /// edit and take `update()`'s result back.
    @inlinable
    public var mutable: Mutable {
        Mutable(self)
    }
}

extension Snapshot: Equatable where Model: Equatable {}
extension Snapshot: Hashable where Model: Hashable {}
extension Snapshot: Sendable where Model: Sendable {}

// MARK: - Typed identity

extension Snapshot: Projection {}

/// The wrap-path `id` witness comes from the `Projection` extension:
/// `Identifier<Model, Model.ID>`.
extension Snapshot: Identifiable where Model: Identifiable {
    public typealias ID = Identifier<Model, Model.ID>
}

/// Pass-through: a model that already owns an `Identifier<Self, _>` id gets
/// it exposed as-is, not double-wrapped. This is an overload, not a second
/// conformance (Swift allows one): concrete call sites resolve here; generic
/// `Identifiable` contexts still see the wrapping witness, which nests the
/// identifier — functionally correct, just a wider type.
extension Snapshot where Model: Identifiable, Model.ID: IdentifierProtocol, Model.ID.Owner == Model {
    @inlinable
    public var id: Model.ID {
        wrappedValue.id
    }
}

// MARK: - Descriptions

extension Snapshot: CustomStringConvertible {
    public var description: String {
        String(describing: wrappedValue)
    }
}

extension Snapshot: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Snapshot<\(Model.self)>(\(wrappedValue))"
    }
}

// MARK: - Comparable

extension Snapshot: Comparable where Model: Comparable {
    @inlinable
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.wrappedValue < rhs.wrappedValue
    }
}

// MARK: - Codable (round-trips as the bare model)

extension Snapshot: Decodable where Model: Decodable {
    public init(from decoder: any Decoder) throws {
        // Same strategy as Identifier (from swift-tagged): the container
        // path handles Optional/null, the fallback respects decoder
        // strategies (dates, data, …).
        do {
            self.init(try decoder.singleValueContainer().decode(Model.self))
        } catch {
            self.init(try Model(from: decoder))
        }
    }
}

extension Snapshot: Encodable where Model: Encodable {
    public func encode(to encoder: any Encoder) throws {
        do {
            var container = encoder.singleValueContainer()
            try container.encode(wrappedValue)
        } catch {
            try wrappedValue.encode(to: encoder)
        }
    }
}

// MARK: - Collection (elements are themselves projected)

/// A projection over a collection model vends *projected* elements:
/// `Snapshot<[Part]>` is a `Collection` of `Snapshot<Part>`.
extension Snapshot: Sequence where Model: Collection {}

extension Snapshot: Collection where Model: Collection {
    public typealias Index = Model.Index
    public typealias Element = Snapshot<Model.Element>

    @inlinable public var startIndex: Model.Index { wrappedValue.startIndex }
    @inlinable public var endIndex: Model.Index { wrappedValue.endIndex }

    @inlinable
    public subscript(position: Model.Index) -> Snapshot<Model.Element> {
        Snapshot<Model.Element>(wrappedValue[position])
    }

    @inlinable
    public func index(after i: Model.Index) -> Model.Index {
        wrappedValue.index(after: i)
    }

    // Explicit forwarding so the model's O(1) implementations are used
    // instead of the O(n) protocol defaults (swift-tagged PR #88 lesson).
    @inlinable
    public func index(_ i: Model.Index, offsetBy distance: Int) -> Model.Index {
        wrappedValue.index(i, offsetBy: distance)
    }

    @inlinable
    public func distance(from start: Model.Index, to end: Model.Index) -> Int {
        wrappedValue.distance(from: start, to: end)
    }

    @inlinable public var count: Int { wrappedValue.count }
    @inlinable public var isEmpty: Bool { wrappedValue.isEmpty }
}

extension Snapshot: BidirectionalCollection where Model: BidirectionalCollection {
    @inlinable
    public func index(before i: Model.Index) -> Model.Index {
        wrappedValue.index(before: i)
    }
}

extension Snapshot: RandomAccessCollection where Model: RandomAccessCollection {}
