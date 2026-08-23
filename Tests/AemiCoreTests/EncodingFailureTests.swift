import Foundation
import Testing
import AemiCore

private enum Part {}

/// A raw value that fails to encode, recording how many times it was asked.
/// The attempt number rides along in the error, so a silent retry is visible in
/// what the caller finally sees.
private struct CountingFailure: Encodable {
    final class Attempts: @unchecked Sendable {
        var count = 0
    }

    struct Failure: Error, Equatable {
        let attempt: Int
    }

    let attempts: Attempts

    func encode(to encoder: any Encoder) throws {
        attempts.count += 1
        throw Failure(attempt: attempts.count)
    }
}

/// `encode(to:)` must surface the encoder's first failure. Retrying the value
/// against the same encoder masks the original error behind a second one and
/// asks an encoder that already holds a container to produce another.
@Suite("Encoding failure propagation")
struct EncodingFailureTests {

    @Test
    func `the first encoding failure reaches the caller unmasked`() throws {
        let attempts = CountingFailure.Attempts()
        let sut = Identifier<Part, CountingFailure>(CountingFailure(attempts: attempts))

        let error = #expect(throws: CountingFailure.Failure.self) {
            try JSONEncoder().encode([sut])
        }

        #expect(error == CountingFailure.Failure(attempt: 1))
        #expect(attempts.count == 1, "the raw value must be asked to encode exactly once")
    }

    /// The decode side keeps its fallback: the container path handles `null`
    /// and the fallback respects decoder strategies. These pin that the encode
    /// change did not disturb it.
    @Test
    func `a date identifier still round trips under a custom strategy`() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let sut = Identifier<Part, Date>(Date(timeIntervalSince1970: 1_700_000_000))
        let data = try encoder.encode([sut])
        #expect(String(decoding: data, as: UTF8.self) == "[1700000000]")

        let decoded = try decoder.decode([Identifier<Part, Date>].self, from: data)
        #expect(decoded == [sut])
    }

    @Test
    func `an identifier encodes as its bare raw value`() throws {
        let data = try JSONEncoder().encode([Identifier<Part, Int>(42)])
        #expect(String(decoding: data, as: UTF8.self) == "[42]")

        let text = try JSONEncoder().encode([Identifier<Part, String>("abc")])
        #expect(String(decoding: text, as: UTF8.self) == "[\"abc\"]")
    }

    @Test
    func `an optional identifier encodes as null and decodes back`() throws {
        let sut: Identifier<Part, Int>? = nil
        let data = try JSONEncoder().encode([sut])
        #expect(String(decoding: data, as: UTF8.self) == "[null]")

        let decoded = try JSONDecoder().decode([Identifier<Part, Int>?].self, from: data)
        #expect(decoded == [nil])
    }
}
