import Testing
import AemiCore

private enum Ticket {}
private enum Part {}

/// `Strideable` is the only part of `Tagged`'s arithmetic tower that suits an
/// identifier. It makes a run of sequential identifiers countable and gives a
/// type-safe `distance(to:)`, while `id1 + id2` remains a compile error because
/// `Strideable` refines only `Comparable`.
///
/// The standard library supplies no `+`/`-` to arbitrary conformers, and this
/// module adds none, so the tests exercise `advanced(by:)` and `distance(to:)`.
@Suite("Stride and parsing")
struct StrideAndParsingTests {
    private typealias TicketID = Identifier<Ticket, Int>

    @Test
    func `distance between identifiers is a stride, not an identifier`() {
        #expect(TicketID(3).distance(to: TicketID(10)) == 7)
        #expect(TicketID(10).distance(to: TicketID(3)) == -7)
        #expect(TicketID(5).distance(to: TicketID(5)) == 0)
    }

    @Test
    func `advancing by a stride yields another identifier`() {
        #expect(TicketID(3).advanced(by: 7) == TicketID(10))
        #expect(TicketID(3).advanced(by: 0) == TicketID(3))
        #expect(TicketID(3).advanced(by: -5) == TicketID(-2))
        #expect(TicketID(3).advanced(by: -1) == TicketID(2))
    }

    /// The stride overload captures an integer literal in preference to the
    /// identifier's own `ExpressibleByIntegerLiteral` conformance, so `id + 1`
    /// offsets rather than failing to resolve.
    @Test
    func `offsetting operators move an identifier by a stride`() {
        #expect(TicketID(3) + 1 == TicketID(4))
        #expect(1 + TicketID(3) == TicketID(4))
        #expect(TicketID(3) - 1 == TicketID(2))
        #expect(TicketID(3) + 0 == TicketID(3))
        #expect(TicketID(3) + -3 == TicketID(0))

        var sut = TicketID(10)
        sut += 5
        #expect(sut == TicketID(15))
        sut -= 20
        #expect(sut == TicketID(-5))
    }

    /// Subtracting two identifiers measures a gap, so the result is a stride.
    /// Adding two identifiers has no meaning and no overload.
    @Test
    func `the difference of two identifiers is a stride`() {
        let gap: Int = TicketID(10) - TicketID(3)
        #expect(gap == 7)
        #expect(TicketID(3) - TicketID(10) == -7)
        #expect(TicketID(5) - TicketID(5) == 0)
    }

    @Test
    func `a range of identifiers iterates in order`() {
        let sut = Array(TicketID(1)..<TicketID(5))
        #expect(sut == [TicketID(1), TicketID(2), TicketID(3), TicketID(4)])
        #expect(Array(TicketID(1)...TicketID(3)).count == 3)
        #expect(Array(TicketID(0)..<TicketID(0)).isEmpty)
    }

    @Test
    func `stride by a step visits every nth identifier`() {
        let sut = Array(stride(from: TicketID(0), to: TicketID(10), by: 3))
        #expect(sut.map(\.rawValue) == [0, 3, 6, 9])
        #expect(Array(stride(from: TicketID(0), through: TicketID(9), by: 3)).count == 4)
    }

    @Test(arguments: [Int.min + 1, -1, 0, 1, Int.max - 1])
    func `advancing by zero is the identity at every boundary`(value: Int) {
        #expect(TicketID(value).advanced(by: 0) == TicketID(value))
        #expect(TicketID(value).distance(to: TicketID(value)) == 0)
    }

    /// `parse` is a named factory rather than a `LosslessStringConvertible`
    /// conformance. The conformance would add `init?(_ String)`, which outranks
    /// `init(_ RawValue)` when the raw value is `String` and silently makes
    /// every string-backed identifier optional at its call site.
    @Test
    func `parse reads an identifier from its string form`() {
        #expect(TicketID.parse("42") == TicketID(42))
        #expect(TicketID.parse("-7") == TicketID(-7))
        #expect(TicketID.parse("0") == TicketID(0))
    }

    @Test(arguments: ["", " ", "nope", "4 2", "4.2", "0x2A", "٤٢"])
    func `parse rejects input the raw value cannot represent`(input: String) {
        #expect(TicketID.parse(input) == nil)
    }

    @Test
    func `parse round trips through the description`() {
        let sut = TicketID(12345)
        #expect(TicketID.parse(sut.description) == sut)
    }

    /// The reason `LosslessStringConvertible` is absent: this initializer must
    /// stay non-optional.
    @Test
    func `a string backed identifier initializes without optional promotion`() {
        let sut = Identifier<Part, String>("alpha")
        #expect(sut.rawValue == "alpha")
        #expect(Identifier<Part, String>.parse("alpha") == sut)
    }
}
