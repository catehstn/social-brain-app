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
}
