import Testing
import Foundation
@testable import SocialBrain

@Suite("Amazon KDP Importer Tests")
struct AmazonKDPImporterTests {

    private let importer = AmazonKDPImporter()

    // MARK: - Units sold

    @Test("Parses units_sold from standard TSV")
    func parsesUnitsSold() throws {
        let tsv = """
        Title\tAuthor Name\tASIN\tMarketplace\tNet Units Sold\tRoyalties (USD)
        My Book\tJane Smith\tB001\tUS\t12\t18.50
        Another Book\tJane Smith\tB002\tUS\t5\t7.25
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.platform == .amazon)
        #expect(result.intMetric("units_sold") == 17)
    }

    @Test("Counts titles_with_sales (excludes zero-unit titles)")
    func countsTitlesWithSales() throws {
        let tsv = """
        Title\tAuthor Name\tASIN\tMarketplace\tNet Units Sold\tRoyalties (USD)
        Book A\tAuthor\tB001\tUS\t3\t4.50
        Book B\tAuthor\tB002\tUS\t0\t0.00
        Book C\tAuthor\tB003\tUS\t7\t10.50
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("titles_with_sales") == 2)
    }

    // MARK: - Royalties

    @Test("Sums royalties_usd")
    func sumsRoyalties() throws {
        let tsv = """
        Title\tAuthor Name\tASIN\tMarketplace\tNet Units Sold\tRoyalties (USD)
        Book A\tAuthor\tB001\tUS\t5\t7.50
        Book A\tAuthor\tB001\tUK\t3\t3.00
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        let royalties = try #require(result.doubleMetric("royalties_usd"))
        #expect(abs(royalties - 10.50) < 0.001)
    }

    @Test("Strips $ sign from royalty column")
    func stripsDollarSign() throws {
        let tsv = """
        Title\tAuthor Name\tASIN\tMarketplace\tNet Units Sold\tRoyalties (USD)
        Book A\tAuthor\tB001\tUS\t1\t$2.99
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        let royalties = try #require(result.doubleMetric("royalties_usd"))
        #expect(abs(royalties - 2.99) < 0.001)
    }

    // MARK: - KENP pages

    @Test("Parses kenp_pages_read when column is present")
    func parsesKenpPages() throws {
        let tsv = """
        Title\tAuthor Name\tASIN\tMarketplace\tKENP Read
        Book A\tAuthor\tB001\tUS\t4200
        Book B\tAuthor\tB002\tUS\t800
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("kenp_pages_read") == 5000)
    }

    @Test("Omits kenp_pages_read when column is absent")
    func omitsKenpWhenAbsent() throws {
        let tsv = """
        Title\tAuthor Name\tASIN\tMarketplace\tNet Units Sold
        Book A\tAuthor\tB001\tUS\t3
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("kenp_pages_read") == nil)
    }

    // MARK: - Report-preamble header

    @Test("Skips report-preamble lines before the column header")
    func skipsPreamble() throws {
        let tsv = """
        Prior Months' Royalties Report
        Generated: January 2026

        Title\tAuthor Name\tASIN\tMarketplace\tNet Units Sold\tRoyalties (USD)
        My Book\tJane\tB001\tUS\t4\t6.00
        """
        let data = try #require(tsv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("units_sold") == 4)
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
        let tsv = "foo\tbar\tbaz\n1\t2\t3\n"
        let data = tsv.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }
}
