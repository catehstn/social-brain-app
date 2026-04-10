import Testing
import Foundation
import GRDB
@testable import SocialBrain

@Suite("FeedViewModel")
@MainActor
struct FeedViewModelTests {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase.makeInMemory()
    }

    // Helper: create a run and return its ID
    private func makeRun(in db: AppDatabase) async throws -> Int64 {
        var run = CollectionRun(
            id: nil, startedAt: Date(), completedAt: nil,
            platformCount: 1, errorCount: 0
        )
        try await db.saveRun(&run)
        return try #require(run.id)
    }

    @Test("load() populates cards from snapshots")
    func loadsCards() async throws {
        let db = try makeDB()
        let runID = try await makeRun(in: db)
        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "Test post", followersCount: 200, engagementRate: 0.1))
        var snap = PlatformSnapshot(runID: runID, platform: "mastodon",
                                    collectedAt: Date(), metricsJSON: payload)
        try await db.saveSnapshot(&snap)

        let vm = FeedViewModel(database: db)
        await vm.load()

        #expect(!vm.cards.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test("empty database has non-empty cards (stale reminders)")
    func emptyDatabaseHasNonEmptyCards() async throws {
        let db = try makeDB()
        let vm = FeedViewModel(database: db)
        await vm.load()
        #expect(!vm.cards.isEmpty)
    }

    @Test("load() with empty database produces 4 stale reminder cards")
    func emptyDatabaseProducesStaleReminders() async throws {
        let db = try makeDB()
        let vm = FeedViewModel(database: db)
        await vm.load()
        // stale reminders for linkedin, substack, amazon, oreilly
        #expect(vm.cards.filter { $0.cardType == .staleReminder }.count == 4)
    }

    @Test("stale snapshot produces stale reminder card")
    func staleReminderCard() async throws {
        let db = try makeDB()
        let fixedNow = Date()
        let staleDate = fixedNow.addingTimeInterval(-(4 * 24 * 3600)) // 4 days ago
        let runID = try await makeRun(in: db)
        let payload = try JSONEncoder().encode(LinkedInData(
            latestPostText: "old post", totalImpressions: 50))
        var snap = PlatformSnapshot(runID: runID, platform: "linkedin",
                                    collectedAt: staleDate, metricsJSON: payload)
        try await db.saveSnapshot(&snap)

        let vm = FeedViewModel(database: db, now: { fixedNow })
        await vm.load()

        let stale = vm.cards.first { (card: FeedCard) in
            card.platform == .linkedin && card.cardType == .staleReminder
        }
        #expect(stale != nil)
    }

    @Test("fresh snapshot does not produce stale reminder")
    func freshSnapshotNoStaleReminder() async throws {
        let db = try makeDB()
        let fixedNow = Date()
        let freshDate = fixedNow.addingTimeInterval(-(1 * 24 * 3600)) // 1 day ago
        let runID = try await makeRun(in: db)
        let payload = try JSONEncoder().encode(LinkedInData(
            latestPostText: "fresh", totalImpressions: 10))
        var snap = PlatformSnapshot(runID: runID, platform: "linkedin",
                                    collectedAt: freshDate, metricsJSON: payload)
        try await db.saveSnapshot(&snap)

        let vm = FeedViewModel(database: db, now: { fixedNow })
        await vm.load()

        let stale = vm.cards.filter { (card: FeedCard) in
            card.platform == .linkedin && card.cardType == .staleReminder
        }
        #expect(stale.isEmpty == true)
    }

    @Test("navigationTarget matches platform")
    func navigationTarget() async throws {
        let db = try makeDB()
        let runID = try await makeRun(in: db)
        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "nav test", followersCount: 10, engagementRate: 0.02))
        var snap = PlatformSnapshot(runID: runID, platform: "mastodon",
                                    collectedAt: Date(), metricsJSON: payload)
        try await db.saveSnapshot(&snap)

        let vm = FeedViewModel(database: db)
        await vm.load()

        let card = vm.cards.first { $0.platform == .mastodon }
        #expect(card?.navigationTarget == .mastodon)
    }
}
