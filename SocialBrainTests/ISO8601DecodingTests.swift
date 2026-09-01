import Testing
import Foundation
@testable import SocialBrain

/// Guards the fractional-seconds handling that `.iso8601` gets wrong.
///
/// These would have caught the Mastodon/Bluesky decoding failure directly,
/// instead of it surfacing as an opaque `decodingError` in a collector test on
/// one toolchain but not another.
@Suite("ISO8601 flexible decoding")
struct ISO8601DecodingTests {

    private struct Wrapper: Decodable {
        let timestamp: Date
    }

    private func decode(_ raw: String) throws -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        let json = Data(#"{"timestamp":"\#(raw)"}"#.utf8)
        return try decoder.decode(Wrapper.self, from: json).timestamp
    }

    @Test("Accepts fractional seconds — the form Mastodon and Bluesky actually send")
    func acceptsFractionalSeconds() throws {
        let date = try decode("2026-03-24T08:00:00.000Z")
        #expect(date == Date(timeIntervalSince1970: 1774339200))
    }

    @Test("Accepts a plain internet date-time with no fractional part")
    func acceptsWithoutFractionalSeconds() throws {
        let date = try decode("2026-03-24T08:00:00Z")
        #expect(date == Date(timeIntervalSince1970: 1774339200))
    }

    @Test("Both spellings of the same instant decode identically")
    func spellingsAgree() throws {
        #expect(try decode("2026-03-24T08:00:00.000Z") == (try decode("2026-03-24T08:00:00Z")))
    }

    @Test("Honours a non-UTC offset")
    func honoursOffset() throws {
        #expect(try decode("2026-03-24T09:00:00.500+01:00")
                == Date(timeIntervalSince1970: 1774339200.5))
    }

    @Test("Rejects a string that is not a date")
    func rejectsGarbage() {
        #expect(throws: DecodingError.self) { try decode("not a date") }
    }
}
