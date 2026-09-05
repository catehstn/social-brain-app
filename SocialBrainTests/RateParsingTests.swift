import Testing
import Foundation
@testable import SocialBrain

/// The magnitude heuristic these replace (`value > 1 ? value / 100 : value`)
/// existed in two copies and was wrong in both, for the common case rather than
/// the edge case: typical post and newsletter click rates are below 1%, and
/// every one of those was inflated 100x on its way into the prompt.
@Suite("Rate parsing")
struct RateParsingTests {

    @Test("A declared percentage column is always divided, whatever the magnitude",
          arguments: [("0.72", 0.0072), ("2.72", 0.0272), ("45.2", 0.452),
                      ("100", 1.0), ("0", 0.0)])
    func percentColumnAlwaysDivides(raw: String, expected: Double) {
        let value = RateParsing.rate(from: raw, isPercentColumn: true)
        #expect(value != nil)
        #expect(abs((value ?? 0) - expected) < 1e-9, "\(raw) → \(value as Any), expected \(expected)")
    }

    @Test("A literal % in the cell settles it even without a declared column",
          arguments: [("0.72%", 0.0072), ("2.72%", 0.0272), ("45.2 %", 0.452)])
    func literalPercentSignWins(raw: String, expected: Double) {
        let value = RateParsing.rate(from: raw, isPercentColumn: false)
        #expect(value != nil)
        #expect(abs((value ?? 0) - expected) < 1e-9, "\(raw) → \(value as Any), expected \(expected)")
    }

    @Test("With no signal, magnitude decides — a fraction cannot exceed 1",
          arguments: [("0.452", 0.452), ("45.2", 0.452), ("1", 1.0), ("1.5", 0.015)])
    func magnitudeFallback(raw: String, expected: Double) {
        let value = RateParsing.rate(from: raw, isPercentColumn: false)
        #expect(value != nil)
        #expect(abs((value ?? 0) - expected) < 1e-9, "\(raw) → \(value as Any), expected \(expected)")
    }

    @Test("Non-numeric and absent cells yield nil",
          arguments: [nil, "", "n/a", "—", "%", "abc"])
    func rejectsNonNumeric(raw: String?) {
        #expect(RateParsing.rate(from: raw, isPercentColumn: true) == nil)
        #expect(RateParsing.rate(from: raw, isPercentColumn: false) == nil)
    }

    @Test("Whitespace is tolerated, including before a trailing % sign")
    func toleratesWhitespace() {
        // Tolerance rather than equality: 2.72 / 100 is 0.027200000000000002.
        #expect(abs((RateParsing.rate(from: "  2.72  ", isPercentColumn: true) ?? 0) - 0.0272) < 1e-9)
        #expect(abs((RateParsing.rate(from: " 2.72 % ", isPercentColumn: false) ?? 0) - 0.0272) < 1e-9)
    }

    @Test("Non-finite input is rejected rather than propagated")
    func rejectsNonFinite() {
        // Double("inf") parses; letting it through would put an unencodable
        // value into a snapshot, which is what aborted runs in #69.
        #expect(RateParsing.rate(from: "inf", isPercentColumn: true) == nil)
        #expect(RateParsing.rate(from: "nan", isPercentColumn: false) == nil)
    }
}
