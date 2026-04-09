import Testing
import Foundation
@testable import SocialBrain

@Suite("Jetpack Collector Tests")
struct JetpackCollectorTests {

    private static let siteID = "12345678"

    private static let statsJSON = """
    {
      "stats": {
        "followers_blog": 1240,
        "followers_comments": 85,
        "comments": 342,
        "likes_today": 12
      }
    }
    """

    private static let visitsJSON = """
    {
      "date": "2026-03-26",
      "unit": "day",
      "fields": ["period", "views", "visitors"],
      "data": [
        ["2026-03-25", 156, 42],
        ["2026-03-24", 143, 38],
        ["2026-03-23", 201, 55]
      ]
    }
    """

    private var session: MockURLSession {
        MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (Self.visitsJSON, 200)
        ])
    }

    private var credentials: Credentials {
        Credentials(["access_token": "test-token", "site_code": Self.siteID])
    }

    // MARK: - Metric parsing

    @Test("Parses follower count and comment subscribers")
    func parsesFollowers() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        #expect(data.platform == .jetpack)
        #expect(data.intMetric("followers_blog") == 1240)
        #expect(data.intMetric("followers_comment") == 85)
    }

    @Test("Parses total comments")
    func parsesTotalComments() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        #expect(data.intMetric("total_comments") == 342)
    }

    @Test("Parses likes_today")
    func parsesLikes() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        #expect(data.intMetric("total_likes") == 12)
    }

    @Test("Sums visit data across all rows")
    func sumsVisits() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        // views: 156 + 143 + 201 = 500
        // visitors: 42 + 38 + 55 = 135
        #expect(data.intMetric("total_views") == 500)
        #expect(data.intMetric("total_visitors") == 135)
    }

    @Test("Handles visits response with missing fields gracefully")
    func handlesEmptyVisits() async throws {
        let emptyVisits = """
        { "date": "2026-03-26", "unit": "day", "fields": ["period"], "data": [] }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (emptyVisits, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: nil, credentials: credentials)
        #expect(data.intMetric("total_views") == 0)
        #expect(data.intMetric("total_visitors") == 0)
    }

    // MARK: - Error cases

    @Test("Throws missingCredential when access_token is absent")
    func missingToken() async throws {
        let creds = Credentials(["site_code": Self.siteID])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: session).collect(since: nil, credentials: creds)
        }
    }

    @Test("Throws missingCredential when site_code is absent")
    func missingSiteID() async throws {
        let creds = Credentials(["access_token": "tok"])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: session).collect(since: nil, credentials: creds)
        }
    }

    @Test("Throws on HTTP error")
    func httpError() async throws {
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats": ("{\"error\":\"unauthorized\"}", 401)
        ])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: sess).collect(since: nil, credentials: credentials)
        }
    }
}
