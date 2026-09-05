import Testing
import Foundation
@testable import SocialBrain

@Suite("LinkedIn Importer Tests")
struct LinkedInImporterTests {

    private let importer = LinkedInImporter()

    private let sampleCSV = """
    Date,ShareLink,ShareCommentary,Impressions,Clicks,CTR (%),Likes,Comments,Shares
    2026-01-15,https://www.linkedin.com/post/1,First post text,4523,123,2.72,45,8,12
    2026-02-10,https://www.linkedin.com/post/2,Second post text,3100,87,2.81,31,4,7
    2026-03-01,https://www.linkedin.com/post/3,Third post text,5200,156,3.00,62,11,18
    """

    // MARK: - Basic parsing

    @Test("Counts posts_published")
    func countsPostsPublished() throws {
        let data = try #require(sampleCSV.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.platform == .linkedin)
        #expect(result.intMetric("posts_published") == 3)
    }

    @Test("Sums total_impressions")
    func sumsTotalImpressions() throws {
        let data = try #require(sampleCSV.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_impressions") == 12823)
    }

    @Test("Sums total_likes")
    func sumsTotalLikes() throws {
        let data = try #require(sampleCSV.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_likes") == 138)
    }

    @Test("Sums total_comments")
    func sumsTotalComments() throws {
        let data = try #require(sampleCSV.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_comments") == 23)
    }

    @Test("Sums total_shares")
    func sumsTotalShares() throws {
        let data = try #require(sampleCSV.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_shares") == 37)
    }

    @Test("Computes average CTR normalised to 0–1")
    func computesAvgCTR() throws {
        let data = try #require(sampleCSV.data(using: .utf8))
        let result = try importer.parse(data: data)
        // (2.72 + 2.81 + 3.00) / 3 / 100 ≈ 0.0284
        let ctr = try #require(result.doubleMetric("avg_ctr"))
        #expect(abs(ctr - (2.72 + 2.81 + 3.00) / 3 / 100) < 0.001)
    }

    @Test("Sub-1% CTR is not inflated 100x")
    func subOnePercentCTRIsNotInflated() throws {
        // The bug: the old heuristic only divided values above 1, so a genuine
        // 0.72% in a column literally headed "CTR (%)" was stored as 0.72 —
        // i.e. 72%. Typical post CTRs are below 1%, so this was the normal case.
        let csv = """
        Date,ShareLink,ShareCommentary,Impressions,Clicks,CTR (%),Likes,Comments,Shares
        2026-01-15,https://www.linkedin.com/post/1,Post,10000,72,0.72,4,1,0
        2026-02-10,https://www.linkedin.com/post/2,Post,20000,96,0.48,3,0,1
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)

        let ctr = try #require(result.doubleMetric("avg_ctr"))
        #expect(abs(ctr - (0.0072 + 0.0048) / 2) < 1e-9)
        // Sanity: a click-through rate above 100% is not a thing.
        #expect(ctr < 1.0)
    }

    @Test("CTR values carrying a literal % sign parse the same way")
    func ctrWithPercentSign() throws {
        let csv = """
        Date,ShareLink,ShareCommentary,Impressions,Clicks,CTR (%),Likes,Comments,Shares
        2026-01-15,https://www.linkedin.com/post/1,Post,10000,72,0.72%,4,1,0
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)

        let ctr = try #require(result.doubleMetric("avg_ctr"))
        #expect(abs(ctr - 0.0072) < 1e-9)
    }

    @Test("The real Page-export header is read as a fraction, not a percentage")
    func pageExportHeaderIsAFraction() throws {
        // Real company Page exports head this column "Click through rate (CTR)"
        // and store a fraction: 328 clicks / 1369 impressions appears as
        // 0.239590943. Treating it as a percentage would divide by 100 again.
        let csv = """
        Date,ShareLink,ShareCommentary,Impressions,Clicks,Click through rate (CTR),Likes,Comments,Shares
        2026-01-15,https://www.linkedin.com/post/1,Post,1369,328,0.239590943,4,1,0
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)

        let ctr = try #require(result.doubleMetric("avg_ctr"))
        #expect(abs(ctr - 0.239590943) < 1e-9)
    }

    @Test("A bare ctr header falls back to magnitude rather than guessing percent")
    func bareCtrHeaderUsesMagnitude() throws {
        let csv = """
        Date,ShareLink,ShareCommentary,Impressions,Clicks,CTR,Likes,Comments,Shares
        2026-01-15,https://www.linkedin.com/post/1,Post,10000,72,0.0072,4,1,0
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)

        // Already a fraction; must not be divided again.
        let ctr = try #require(result.doubleMetric("avg_ctr"))
        #expect(abs(ctr - 0.0072) < 1e-9)
    }

    // MARK: - Edge cases

    @Test("Omits engagement metrics when all zeros")
    func omitsZeroEngagement() throws {
        let csv = """
        Date,ShareLink,ShareCommentary,Impressions,Clicks,CTR (%),Likes,Comments,Shares
        2026-01-15,https://link,Post text,500,0,0,0,0,0
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_likes") == nil)
        #expect(result.intMetric("total_comments") == nil)
    }

    @Test("Handles file with only required impressions column")
    func handlesMinimalColumns() throws {
        let csv = """
        Date,Impressions
        2026-01-15,1500
        2026-02-15,2000
        """
        let data = try #require(csv.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("posts_published") == 2)
        #expect(result.intMetric("total_impressions") == 3500)
    }

    // MARK: - Error cases

    @Test("Throws on empty file")
    func emptyFileThrows() {
        let data = Data()
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }

    @Test("Throws when impressions column is absent")
    func missingImpressionsThrows() {
        let csv = "Date,Clicks,Likes\n2026-01-15,10,5\n"
        let data = csv.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }
}
