import Testing
import Foundation
@testable import SocialBrain

// MARK: - Stub collector

private struct StubCollector: Collector {
    let platform: Platform
    var instanceName: String = "default"
    let result: Result<PlatformData, Error>

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        try result.get()
    }
}

// MARK: - Tests

@Suite("Collection Engine Tests")
struct CollectionEngineTests {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase.makeInMemory()
    }

    private func makeCredentials() -> @Sendable (PlatformInstance) throws -> Credentials? {
        return { _ in Credentials(["api_key": "test"]) }
    }

    @Test("Successful run saves snapshots and returns correct summary")
    func successfulRun() async throws {
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            StubCollector(
                platform: .mastodon,
                result: .success(PlatformData(
                    platform: .mastodon,
                    metrics: ["followers_count": .int(1000)]
                ))
            ),
            StubCollector(
                platform: .bluesky,
                result: .success(PlatformData(
                    platform: .bluesky,
                    metrics: ["followers_count": .int(500)]
                ))
            )
        ]

        let summary = try await engine.run(
            collectors: collectors,
            credentials: makeCredentials()
        )

        #expect(summary.platformCount == 2)
        #expect(summary.successCount  == 2)
        #expect(summary.errorCount    == 0)
        #expect(summary.runID > 0)

        let snapshots = try await db.snapshots(forRunID: summary.runID)
        #expect(snapshots.count == 2)
        let platforms = Set(snapshots.compactMap(\.platformEnum))
        #expect(platforms.contains(.mastodon))
        #expect(platforms.contains(.bluesky))

        let runs = try await db.allRuns()
        #expect(runs[0].completedAt != nil)
        #expect(runs[0].errorCount == 0)
    }

    @Test("Partial failure still saves successful snapshots")
    func partialFailure() async throws {
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            StubCollector(
                platform: .mastodon,
                result: .success(PlatformData(
                    platform: .mastodon,
                    metrics: ["followers_count": .int(1000)]
                ))
            ),
            StubCollector(
                platform: .bluesky,
                result: .failure(CollectorError.httpError(statusCode: 401, body: "Unauthorized"))
            )
        ]

        let summary = try await engine.run(
            collectors: collectors,
            credentials: makeCredentials()
        )

        #expect(summary.platformCount == 2)
        #expect(summary.successCount  == 1)
        #expect(summary.errorCount    == 1)

        let snapshots = try await db.snapshots(forRunID: summary.runID)
        // Only the successful platform saved a snapshot
        #expect(snapshots.count == 1)
        #expect(snapshots[0].platformEnum == .mastodon)

        let runs = try await db.allRuns()
        #expect(runs[0].errorCount == 1)
    }

    @Test("Missing credentials results in failure, not crash")
    func missingCredentials() async throws {
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            StubCollector(
                platform: .mastodon,
                result: .success(PlatformData(platform: .mastodon, metrics: [:]))
            )
        ]

        let noCredentials: @Sendable (PlatformInstance) throws -> Credentials? = { _ in nil }
        let summary = try await engine.run(collectors: collectors, credentials: noCredentials)

        // No credentials → failure result, not a thrown error
        #expect(summary.errorCount == 1)
        #expect(summary.successCount == 0)
    }

    @Test("Progress callback is called for each result")
    func progressCallback() async throws {
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            StubCollector(platform: .mastodon, result: .success(PlatformData(platform: .mastodon, metrics: [:]))),
            StubCollector(platform: .bluesky,  result: .success(PlatformData(platform: .bluesky,  metrics: [:])))
        ]

        let counter = Counter()
        try await engine.run(
            collectors: collectors,
            credentials: makeCredentials(),
            progress: { _ in await counter.increment() }
        )

        let count = await counter.value
        #expect(count == 2)
    }

    @Test("Empty collectors list produces a run with zero results")
    func emptyCollectors() async throws {
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let summary = try await engine.run(collectors: [], credentials: makeCredentials())

        #expect(summary.platformCount == 0)
        #expect(summary.successCount  == 0)
        #expect(summary.errorCount    == 0)

        let runs = try await db.allRuns()
        #expect(runs.count == 1)
        #expect(runs[0].completedAt != nil)
    }

    @Test("Two collectors for same platform with different instanceNames each save a snapshot")
    func multiInstanceCollectorsRunAndSave() async throws {
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            StubCollector(
                platform: .mastodon,
                instanceName: "personal",
                result: .success(PlatformData(
                    platform: .mastodon,
                    instanceName: "personal",
                    metrics: ["followers_count": .int(100)]
                ))
            ),
            StubCollector(
                platform: .mastodon,
                instanceName: "work",
                result: .success(PlatformData(
                    platform: .mastodon,
                    instanceName: "work",
                    metrics: ["followers_count": .int(500)]
                ))
            )
        ]

        let summary = try await engine.run(collectors: collectors, credentials: makeCredentials())
        #expect(summary.successCount == 2)
        #expect(summary.errorCount == 0)

        let snapshots = try await db.snapshots(forRunID: summary.runID)
        #expect(snapshots.count == 2)
        let instanceNames = Set(snapshots.map(\.instanceName))
        #expect(instanceNames == ["personal", "work"])
    }

    @Test("A platform whose metrics cannot be persisted does not abort the run")
    func unpersistableMetricsDoNotAbortTheRun() async throws {
        // This is what a NaN used to do: JSONEncoder throws inside the persist
        // loop, the throw propagated out of run(), every snapshot after it went
        // unsaved and completeRun never ran — leaving a dangling open run.
        let db = try makeDB()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            StubCollector(
                platform: .mastodon,
                result: .success(PlatformData(
                    platform: .mastodon,
                    metrics: ["followers_count": .int(1000)]
                ))
            ),
            StubCollector(
                platform: .buttondown,
                result: .success(PlatformData(
                    platform: .buttondown,
                    metrics: ["avg_click_rate": .double(.nan)]
                ))
            ),
            StubCollector(
                platform: .bluesky,
                result: .success(PlatformData(
                    platform: .bluesky,
                    metrics: ["followers_count": .int(50)]
                ))
            )
        ]

        let summary = try await engine.run(
            collectors: collectors,
            credentials: makeCredentials(),
            since: nil,
            progress: nil
        )

        // The bad platform is reported as a failure...
        #expect(summary.results.count == 3)
        let failed = summary.results.filter { !$0.isSuccess }
        #expect(failed.count == 1)
        #expect(failed.first?.instance.platform == .buttondown)

        // ...the other two are still saved...
        let snapshots = try await db.latestSnapshots()
        #expect(snapshots.count == 2)
        #expect(!snapshots.keys.contains { $0.platform == .buttondown })

        // ...and the run is closed rather than left dangling.
        let runs = try await db.allRuns(limit: 1)
        #expect(runs.first?.completedAt != nil)
        #expect(runs.first?.errorCount == 1)
    }
}

// MARK: - Helpers

/// A Sendable counter for use in async test callbacks.
private actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
