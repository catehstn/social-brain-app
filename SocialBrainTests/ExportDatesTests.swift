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
    // MARK: - Why periodEnd is separate from collectedAt

    @Test("Importing the same export twice does not crash latestSnapshots")
    func doubleImportDoesNotCrash() async throws {
        // latestSnapshots() builds a Dictionary(uniqueKeysWithValues:), which is
        // a precondition — duplicate keys trap, and no caller's do/catch can
        // absorb that. Dating snapshots from the export made two imports of one
        // file produce byte-identical timestamps, so dropping a file twice hard-
        // crashed the Feed and Dashboard tabs.
        let db = try AppDatabase.makeInMemory()
        let csv = """
        post_id,post_date,title,open_rate
        1,2026-03-20,Only,0.45
        """
        let data = try #require(csv.data(using: .utf8))

        for _ in 0..<2 {
            let parsed = try SubstackImporter().parse(data: data)
            var run = CollectionRun(startedAt: Date(), platformCount: 1, errorCount: 0)
            try await db.saveRun(&run)
            var snapshot = try PlatformSnapshot(runID: run.id!, data: parsed)
            try await db.saveSnapshot(&snapshot)
        }

        let latest = try await db.latestSnapshots()
        #expect(latest.count == 1)
        // The period still comes from the file even though both rows share it.
        #expect(latest.values.first?.periodEnd == ExportDates.date(from: "2026-03-20"))
    }

    @Test("An export whose newest post is old is not born stale")
    func oldExportIsNotBornStale() throws {
        // Substack's stale threshold is 3 days. Dating the snapshot from the
        // export meant any weekly newsletter's export was stale the moment it
        // was imported — inverting the card's meaning from "you haven't
        // re-exported" to "you haven't published".
        let old = Date().addingTimeInterval(-30 * 86_400)
        let snapshot = try PlatformSnapshot(
            runID: 1,
            data: PlatformData(platform: .substack, periodEnd: old, metrics: ["posts_published": .int(3)])
        )

        // The staleness clock reads collectedAt, which is the import time.
        #expect(abs(snapshot.collectedAt.timeIntervalSinceNow) < 60)
        #expect(snapshot.periodEnd == old)
    }

    @Test("Two snapshots of the same period are still distinguishable in time")
    func sameperiodSnapshotsAreOrdered() throws {
        // SpikeDetector compares the two most recent snapshots. If both carried
        // the export's date they would be identical and every real change would
        // read as 0%.
        let period = Date(timeIntervalSince1970: 1_767_225_600)
        let first = try PlatformSnapshot(
            runID: 1, data: PlatformData(platform: .substack, periodEnd: period, metrics: [:])
        )
        let second = try PlatformSnapshot(
            runID: 2, data: PlatformData(platform: .substack, periodEnd: period, metrics: [:])
        )

        #expect(first.periodEnd == second.periodEnd)
        #expect(first.collectedAt != second.collectedAt)
    }

}
