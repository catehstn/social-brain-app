import Testing
import Foundation
@testable import SocialBrain

@Suite("Vercel Collector Tests")
struct VercelCollectorTests {

    private static let deploymentsJSON = """
    {
      "deployments": [
        { "uid": "dep_1", "target": "production", "state": "READY"  },
        { "uid": "dep_2", "target": "preview",    "state": "READY"  },
        { "uid": "dep_3", "target": "production", "state": "ERROR"  },
        { "uid": "dep_4", "target": "preview",    "state": "READY"  }
      ]
    }
    """

    @Test("Counts total, production, and error deployments")
    func collectMetrics() async throws {
        let session = MockURLSession([
            "/v6/deployments": (VercelCollectorTests.deploymentsJSON, 200)
        ])
        let collector = VercelCollector(
            session: session,
            baseURL: URL(string: "https://api.vercel.com")!
        )
        let credentials = Credentials([
            "api_key":   "test-token",
            "site_code": "my-project"
        ])
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.platform == .vercel)
        #expect(data.intMetric("deployments")            == 4)
        #expect(data.intMetric("production_deployments") == 2)
        #expect(data.intMetric("error_deployments")      == 1)
    }

    @Test("Throws missingCredential when api_key is absent")
    func missingAPIKey() async throws {
        let collector = VercelCollector()
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: Credentials(["site_code": "p"]))
        }
    }

    @Test("Throws missingCredential when site_code is absent")
    func missingSiteCode() async throws {
        let collector = VercelCollector()
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: Credentials(["api_key": "t"]))
        }
    }
}
