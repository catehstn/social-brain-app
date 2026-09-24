import Testing
import Foundation
@testable import SocialBrain

/// `HistoryViewModel` had no tests at all (#90).
///
/// It is small, but it is the only place that pairs runs with their snapshots,
/// and it does so by firing one query per run in a task group — so the things
/// worth pinning are that every run gets its own snapshots, that none are
/// crossed over, and that a failure leaves an empty screen rather than a
/// half-populated one.
@Suite("History view model")
@MainActor
struct HistoryViewModelTests {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase.makeInMemory()
    }

    /// A run, optionally back-dated so ordering can be asserted.
    @discardableResult
    private func makeRun(in db: AppDatabase, startedAt: Date = Date(), platforms: Int = 1) async throws -> Int64 {
        var run = CollectionRun(
            id: nil, startedAt: startedAt, completedAt: nil,
            platformCount: platforms, errorCount: 0
        )
        try await db.saveRun(&run)
        return try #require(run.id)
    }

    private func seed(
        _ db: AppDatabase, runID: Int64, platform: Platform, instanceName: String = "default"
    ) async throws {
        let data = PlatformData(platform: platform, instanceName: instanceName,
                                metrics: ["followers_count": .int(1)])
        var snapshot = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snapshot)
    }

    @Test("Every run is paired with its own snapshots")
    func snapshotsAreKeyedByTheirRun() async throws {
        // The task group returns out of order by design, so this is the
        // assertion that a run cannot end up holding another run's rows.
        let db = try makeDB()
        let first  = try await makeRun(in: db, startedAt: Date(timeIntervalSince1970: 1_000))
        let second = try await makeRun(in: db, startedAt: Date(timeIntervalSince1970: 2_000))
        try await seed(db, runID: first, platform: .mastodon)
        try await seed(db, runID: second, platform: .bluesky)
        try await seed(db, runID: second, platform: .buffer)

        let vm = HistoryViewModel(database: db)
        await vm.load()

        #expect(vm.runs.count == 2)
        #expect(vm.snapshots[first]?.map(\.platformEnum) == [.mastodon])
        #expect(Set(vm.snapshots[second]?.compactMap(\.platformEnum) ?? []) == [.bluesky, .buffer])
    }

    @Test("Runs are newest first")
    func runsAreOrderedNewestFirst() async throws {
        let db = try makeDB()
        let older = try await makeRun(in: db, startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = try await makeRun(in: db, startedAt: Date(timeIntervalSince1970: 9_000))

        let vm = HistoryViewModel(database: db)
        await vm.load()

        #expect(vm.runs.compactMap(\.id) == [newer, older])
    }

    @Test("A run with no snapshots is present, with an empty list")
    func runWithoutSnapshots() async throws {
        // A collection that failed on every platform still produced a run, and
        // the History screen has to show it rather than drop it.
        let db = try makeDB()
        let runID = try await makeRun(in: db)

        let vm = HistoryViewModel(database: db)
        await vm.load()

        #expect(vm.runs.count == 1)
        #expect(vm.snapshots[runID]?.isEmpty == true)
    }

    @Test("An empty database loads to empty, not to a spinner")
    func emptyDatabase() async throws {
        let vm = HistoryViewModel(database: try makeDB())
        await vm.load()

        #expect(vm.runs.isEmpty)
        #expect(vm.snapshots.isEmpty)
        // `isLoading` is cleared in a `defer`, so the empty path clears it too.
        #expect(!vm.isLoading)
    }

    @Test("Loading twice does not accumulate")
    func loadIsIdempotent() async throws {
        // `runs` is assigned, but `snapshots` is a dictionary mutated in place:
        // a second load must not leave rows from the first behind.
        let db = try makeDB()
        let runID = try await makeRun(in: db)
        try await seed(db, runID: runID, platform: .mastodon)

        let vm = HistoryViewModel(database: db)
        await vm.load()
        await vm.load()

        #expect(vm.runs.count == 1)
        #expect(vm.snapshots[runID]?.count == 1)
    }

    @Test("isLoading is false once loading finishes")
    func loadingFlagIsCleared() async throws {
        let db = try makeDB()
        try await makeRun(in: db)

        let vm = HistoryViewModel(database: db)
        #expect(!vm.isLoading)
        await vm.load()
        #expect(!vm.isLoading)
    }
}
