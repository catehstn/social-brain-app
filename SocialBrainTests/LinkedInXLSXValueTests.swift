import Testing
import Foundation
@testable import SocialBrain

/// `Int(Double)` is a **trapping** conversion. `Double("1e999")` parses as
/// infinity and `Int(.infinity)` kills the process — and `try?` does not catch a
/// trap, so a crafted `.xlsx` containing `<v>1e999</v>` crashed the app outright.
///
/// Found while hardening `MiniZIPReader` (#71): bounding the ZIP layer is beside
/// the point while the XML layer above it traps on the same untrusted input.
@Suite("LinkedIn XLSX cell values")
struct LinkedInXLSXValueTests {

    @Test("Values that would trap on conversion are refused",
          arguments: ["1e999", "-1e999", "inf", "-inf", "nan", "1e400", "Infinity"])
    func refusesTrappingValues(raw: String) {
        #expect(LinkedInXLSXParser.safeInt(raw) == nil)
    }

    @Test("Absurd but finite magnitudes are refused rather than dominating a sum")
    func refusesAbsurdMagnitudes() {
        // A single crafted cell could otherwise swamp every real value in a total.
        #expect(LinkedInXLSXParser.safeInt("1e15") == nil)
        #expect(LinkedInXLSXParser.safeInt("-1e15") == nil)
        #expect(LinkedInXLSXParser.safeInt("999999999999999999999") == nil)
    }

    @Test("Ordinary spreadsheet values still convert",
          arguments: [("0", 0), ("42", 42), ("4523", 4523), ("2.9", 2), ("-7", -7)])
    func convertsOrdinaryValues(raw: String, expected: Int) {
        #expect(LinkedInXLSXParser.safeInt(raw) == expected)
    }

    @Test("Non-numeric cells yield nil",
          arguments: ["", "   ", "n/a", "abc"])
    func rejectsNonNumeric(raw: String) {
        #expect(LinkedInXLSXParser.safeInt(raw) == nil)
    }

    @Test("Values just under the magnitude ceiling are accepted")
    func acceptsLargeButPlausible() {
        // Impression counts run to the millions; the ceiling must not clip them.
        #expect(LinkedInXLSXParser.safeInt("999999999") == 999_999_999)
    }
}
