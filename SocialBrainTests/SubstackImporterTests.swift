import Testing
import Foundation
@testable import SocialBrain

@Suite("Substack Importer Tests")
struct SubstackImporterTests {

    private let importer = SubstackImporter()

    // MARK: - Current format

    @Test("Parses posts_published from current format")
    func currentFormatPostCount() throws {
        let csv = """
        title,post_date,delivered,open_rate,opens,likes,comments,shares
        "Post One","2026-01-01","500","0.45","225","10","2","3"
        "Post Two","2026-02-01","520","0.50","260","15","4","6"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.platform == .substack)
        #expect(result.intMetric("posts_published") == 2)
    }

    @Test("Computes average open rate from current format")
    func currentFormatOpenRate() throws {
        let csv = """
        title,post_date,delivered,open_rate
        "A","2026-01-01","500","0.40"
        "B","2026-02-01","500","0.60"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        let rate = try #require(result.doubleMetric("avg_open_rate"))
        #expect(abs(rate - 0.50) < 0.001)
    }

    @Test("Normalises percentage open rate (0–100) to 0–1")
    func normalisesPercentageRate() throws {
        let csv = """
        title,post_date,delivered,open_rate
        "A","2026-01-01","500","45.0"
        "B","2026-02-01","500","55.0"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        let rate = try #require(result.doubleMetric("avg_open_rate"))
        #expect(abs(rate - 0.50) < 0.001)
    }

    @Test("Parses percentage rate with % sign")
    func parsesPercentSign() throws {
        let csv = """
        title,post_date,delivered,open_rate
        "A","2026-01-01","500","42%"
        "B","2026-02-01","500","58%"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        let rate = try #require(result.doubleMetric("avg_open_rate"))
        #expect(abs(rate - 0.50) < 0.001)
    }

    // MARK: - Legacy format

    @Test("Parses posts_published from legacy format")
    func legacyFormatPostCount() throws {
        let csv = """
        Subject,Date,Recipients,Opens,Open rate,Clicks,Click rate,Unsubscribes
        "Newsletter 1","2026-01-01","400","160","40.0%","20","5.0%","2"
        "Newsletter 2","2026-02-01","420","189","45.0%","25","6.0%","1"
        "Newsletter 3","2026-03-01","440","220","50.0%","30","7.0%","0"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("posts_published") == 3)
    }

    @Test("Computes average open rate from legacy format")
    func legacyFormatOpenRate() throws {
        let csv = """
        Subject,Date,Recipients,Opens,Open rate
        "A","2026-01-01","400","160","40.0%"
        "B","2026-02-01","420","210","50.0%"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        let rate = try #require(result.doubleMetric("avg_open_rate"))
        #expect(abs(rate - 0.45) < 0.001)
    }

    // MARK: - Error cases

    @Test("Throws on empty file")
    func emptyFileThrows() {
        let data = Data()
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }

    @Test("Throws on unrecognised format")
    func unrecognisedFormatThrows() {
        let csv = "foo,bar,baz\n1,2,3\n"
        let data = csv.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }

    @Test("Omits avg_open_rate when column is absent")
    func omitsOpenRateWhenAbsent() throws {
        let csv = """
        title,post_date,delivered
        "A","2026-01-01","500"
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.doubleMetric("avg_open_rate") == nil)
    }
    @Test("The export's own period is recorded, without moving the import clock")
    func exportPeriodIsRecorded() throws {
        // Importing an old export used to file it as today's snapshot, so a
        // backfill landed on top of current data.
        let csv = """
        post_id,post_date,title,open_rate,click_rate
        1,2026-01-05,First,0.45,0.05
        2,2026-03-20,Second,0.50,0.06
        3,2026-02-10,Third,0.40,0.04
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try SubstackImporter().parse(data: data)

        // periodEnd is the newest post in the file — not the first row.
        #expect(result.periodEnd == ExportDates.date(from: "2026-03-20"))

        // collectedAt stays the import clock. Moving it broke three things at
        // once: two imports of one file produced identical timestamps and
        // crashed latestSnapshots(), any export older than the staleness
        // threshold was born stale, and SpikeDetector compared a snapshot with
        // its own duplicate.
        #expect(abs(result.collectedAt.timeIntervalSinceNow) < 60)
    }

    @Test("An export with no usable dates records no period rather than the epoch")
    func noPeriodWhenNoDates() throws {
        let csv = """
        post_id,post_date,title,open_rate
        1,,First,0.45
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try SubstackImporter().parse(data: data)

        #expect(result.periodEnd == nil)

        #expect(abs(result.collectedAt.timeIntervalSinceNow) < 60)
    }

}
