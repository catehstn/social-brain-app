import Testing
import Foundation
@testable import SocialBrain

/// File-export importers stamped every snapshot with `.now`, discarding the
/// dates the file carried (#76). Importing an old export therefore filed it as
/// today, which puts history at the wrong point on the Dashboard's axis and
/// makes a backfill look like a sudden change to `SpikeDetector`.
@Suite("Export dates")
struct ExportDatesTests {

    private let expected = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 UTC

    @Test("Parses the formats seen in export files",
          arguments: ["2026-01-01",
                      "2026-01-01 00:00:00",
                      "2026-01-01T00:00:00Z",
                      "2026-01-01T00:00:00.000Z"])
    func parsesKnownFormats(raw: String) {
        #expect(ExportDates.date(from: raw) == expected)
    }

    @Test("Tolerates surrounding whitespace")
    func tolerLatesWhitespace() {
        #expect(ExportDates.date(from: "  2026-01-01  ") == expected)
    }

    @Test("Returns nil rather than a wrong date",
          arguments: [nil, "", "   ", "not a date", "01/01/2026", "2026"])
    func rejectsUnparseable(raw: String?) {
        #expect(ExportDates.date(from: raw) == nil)
    }

    @Test("Parsing is independent of the machine's calendar")
    func parsingIsLocaleIndependent() {
        // A Thai or Persian locale would otherwise read a Gregorian date against
        // a different calendar — the bug found in GoogleSearchConsoleCollector.
        // en_US_POSIX is pinned, so this holds regardless of system settings.
        #expect(ExportDates.date(from: "2026-01-01") == expected)
        #expect(ExportDates.date(from: "2569-01-01") != expected)
    }

    @Test("Picks the most recent date, not the first row")
    func picksLatest() {
        // An export covers a period; the snapshot describes its end.
        let rows = [["a", "2026-01-01"], ["b", "2026-03-15"], ["c", "2026-02-01"]]
        let latest = ExportDates.latest(in: rows, column: 1)

        #expect(latest == ExportDates.date(from: "2026-03-15"))
    }

    @Test("Unparseable rows are skipped rather than poisoning the result")
    func skipsUnparseableRows() {
        let rows = [["a", "n/a"], ["b", "2026-03-15"], ["c", ""]]
        #expect(ExportDates.latest(in: rows, column: 1) == ExportDates.date(from: "2026-03-15"))
    }

    @Test("An absent column yields nil so the caller can fall back")
    func absentColumnIsNil() {
        #expect(ExportDates.latest(in: [["a"]], column: nil) == nil)
        #expect(ExportDates.latest(in: [["a"]], column: 9) == nil)
    }

    @Test("No parseable dates at all yields nil, not the epoch")
    func noDatesIsNil() {
        // Returning .distantPast here would silently file the snapshot in 1
        // AD rather than falling back to now.
        #expect(ExportDates.latest(in: [["x", "junk"], ["y", ""]], column: 1) == nil)
    }
}
