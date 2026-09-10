import Testing
import Foundation
@testable import SocialBrain

/// `decodeJSON`'s failure path (#152).
///
/// Every decode failure used to arrive as `error.localizedDescription`, which
/// for a `DecodingError` is the same sentence regardless of what happened:
/// "The data couldn't be read because it isn't in the correct format." It names
/// neither the field nor the type expected, so a wrong-typed `sent_at` and a
/// wrong-typed `statistics.clicks` are indistinguishable — and nothing was
/// logged either, so there was no second place to look.
@Suite("decodeJSON failure detail")
struct DecodeJSONTests {

    private struct Stats: Decodable {
        let clicks: Int
    }

    private struct Update: Decodable {
        let id: String
        let statistics: Stats?
    }

    private struct Envelope: Decodable {
        let updates: [Update]
    }

    private struct Timestamped: Decodable {
        let createdAt: Date
    }

    private func message(decoding json: String, as type: (some Decodable).Type,
                         decoder: JSONDecoder = JSONDecoder()) throws -> String {
        let url = try #require(URL(string: "https://example.com/updates"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        let data = try #require(json.data(using: .utf8))
        do {
            _ = try decodeJSON(type, from: data, response: response, decoder: decoder)
            Issue.record("expected a decode failure, got a value")
            return ""
        } catch let error as CollectorError {
            return try #require(error.errorDescription)
        }
    }

    @Test("A wrong-typed field is named, along with the type expected")
    func namesTheFieldAndType() throws {
        let msg = try message(
            decoding: #"{"id":"a","statistics":{"clicks":"9"}}"#,
            as: Update.self
        )
        // Not just "isn't in the correct format": which field, and what it
        // should have been.
        #expect(msg.contains("statistics.clicks"))
        #expect(msg.contains("Int"))
    }

    @Test("A missing key names the key that is missing, not its parent")
    func namesTheMissingKey() throws {
        // `keyNotFound` carries the *container's* coding path, so a naive
        // rendering reports the parent and leaves the user hunting.
        let msg = try message(decoding: #"{"statistics":null}"#, as: Update.self)
        #expect(msg.contains("id"))
        #expect(msg.contains("missing"))
    }

    @Test("A failure inside an array carries the index")
    func namesTheArrayIndex() throws {
        let msg = try message(
            decoding: #"""
            {"updates":[{"id":"a"},{"id":7}]}
            """#,
            as: Envelope.self
        )
        // The second element, not the first — an index of 0 would be the value
        // a broken path renders by accident.
        #expect(msg.contains("updates[1].id"))
        #expect(msg.contains("String"))
    }

    @Test("An explicit null for a required field says so")
    func distinguishesNullFromAbsent() throws {
        let msg = try message(decoding: #"{"id":null}"#, as: Update.self)
        #expect(msg.contains("id"))
        #expect(msg.contains("null"))
    }

    @Test("A root-level mismatch reads as a sentence, with no empty field name")
    func rootLevelMismatchHasNoStrayQuotes() throws {
        let msg = try message(decoding: #"[1,2,3]"#, as: Update.self)
        // The field path is empty here. Interpolating it anyway yields
        // "Failed to decode response: '' expected ...".
        #expect(!msg.contains("''"))
        #expect(msg.contains("expected"))
    }

    @Test("The user-facing message never carries the value that failed")
    func theOffendingValueStaysOutOfTheMessage() throws {
        // `iso8601Flexible` writes the raw timestamp into its
        // `debugDescription` (ISO8601Decoding.swift). That field is the one
        // place a DecodingError reliably embeds *data* rather than schema, and
        // this message is rendered on the Run screen — the screen most likely
        // to end up in a screenshot. So debugDescription goes to the log at
        // `.private` and must not reach the string.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let secret = "not-a-date-6QK2WZ"
        let msg = try message(
            decoding: #"{"created_at":"\#(secret)"}"#,
            as: Timestamped.self,
            decoder: decoder
        )

        #expect(!msg.contains(secret))
        // Still useful: it says which field.
        #expect(msg.contains("createdAt"))
    }
}
