import Testing
import Foundation
@testable import SocialBrain

/// #43 retires the Vercel collector, and requires that history already in the
/// store is left alone.
///
/// Removing `Platform.vercel` means those rows no longer map to a case, so they
/// stop appearing in the UI — which is intended. What must *not* happen is their
/// deletion, or a crash when something reads across them.
@Suite("Retired platform data")
struct RetiredPlatformDataTests {

    /// Writes a snapshot for a platform the enum no longer knows about, the way
    /// an older build would have.
    private func seedRetiredRow(_ db: AppDatabase) async throws {
        var run = CollectionRun(startedAt: Date(), platformCount: 1, errorCount: 0)
        try await db.saveRun(&run)
        var snapshot = PlatformSnapshot(
            runID: run.id!,
            platform: "vercel",
            collectedAt: Date(timeIntervalSince1970: 1_767_225_600),
            metricsJSON: Data(#"{"deployments":{"int":12}}"#.utf8)
        )
        try await db.saveSnapshot(&snapshot)
    }

    @Test("Vercel is no longer a known platform")
    func vercelIsRetired() {
        #expect(Platform(rawValue: "vercel") == nil)
        #expect(!Platform.allCases.contains { $0.rawValue == "vercel" })
    }

    @Test("Rows for a retired platform are kept, not deleted")
    func retiredRowsSurvive() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedRetiredRow(db)

        // Read through the app's own accessors, then confirm the row is still
        // on disk. "Left alone" means not deleted, even though nothing displays it.
        _ = try await db.latestSnapshots()
        _ = try await db.allRuns(limit: 10)

        let remaining = try await db.snapshots(forRunID: 1)
        #expect(remaining.count == 1)
        #expect(remaining.first?.platform == "vercel")
    }

    @Test("A retired row is skipped rather than crashing the queries that span it")
    func retiredRowsAreSkippedSafely() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedRetiredRow(db)

        // A live platform alongside it, so the queries have something to return.
        var run = CollectionRun(startedAt: Date(), platformCount: 1, errorCount: 0)
        try await db.saveRun(&run)
        var live = try PlatformSnapshot(
            runID: run.id!,
            data: PlatformData(platform: .mastodon, metrics: ["followers_count": .int(10)])
        )
        try await db.saveSnapshot(&live)

        let latest = try await db.latestSnapshots()
        #expect(latest.count == 1)
        #expect(latest.keys.first?.platform == .mastodon)
        // The retired row contributes nothing and breaks nothing.
        #expect(!latest.keys.contains { $0.platform.rawValue == "vercel" })
    }

    @Test("The platform list is pinned, so a removal or addition is deliberate")
    func platformListIsPinned() {
        #expect(Platform.allCases.map(\.rawValue).sorted() == [
            "amazon", "bluesky", "buffer", "buttondown", "calendly",
            "goat_counter", "google_search_console", "hacker_news", "jetpack",
            "linkedin", "mastodon", "oreilly", "substack"
        ])
    }
}
