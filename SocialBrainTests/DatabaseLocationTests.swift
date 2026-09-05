import Testing
import Foundation
@testable import SocialBrain

/// Guards the isolation added for #100.
///
/// Unit tests are injected into the app host, so launching them runs
/// `SocialBrainApp`, which opens the default database. Before this, that was the
/// user's real store — and because the file is shared by every checkout, an
/// experimental migration run inside an isolated git worktree was applied to it
/// twice. The store happened to be empty; a populated one would have lost
/// history that cannot be re-fetched.
@Suite("Database location")
struct DatabaseLocationTests {

    @Test("Tests are recognised as running under a test host")
    func detectsTestHost() {
        // If this ever fails, every assertion below becomes vacuous and the
        // suite silently starts pointing at the real database again.
        #expect(AppDatabase.isRunningUnderTest)
    }

    @Test("The database path is a throwaway one, not Application Support")
    func pathIsThrowaway() throws {
        let url = try AppDatabase.defaultDatabaseURL()

        #expect(!url.path.contains("Application Support/SocialBrain/analytics.sqlite")
                || url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(url.lastPathComponent == "analytics.sqlite")
    }

    @Test("The path is scoped to this process, so concurrent runs cannot collide")
    func pathIsProcessScoped() throws {
        let url = try AppDatabase.defaultDatabaseURL()
        #expect(url.path.contains("SocialBrainTests-\(ProcessInfo.processInfo.processIdentifier)"))
    }

    @Test("Opening the default database does not touch the real store")
    func openingDefaultDoesNotTouchRealStore() throws {
        let real = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        .appendingPathComponent("SocialBrain/analytics.sqlite")

        let before = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date

        _ = try AppDatabase.makeDefault()

        let after = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        // Under a test host this is the whole point: makeDefault() must be inert
        // with respect to the real file.
        #expect(before == after)
    }

    @Test("The throwaway database is usable and migrated")
    func throwawayDatabaseWorks() async throws {
        let database = try AppDatabase.makeDefault()
        // Reaching a real query proves migrations ran against the temp file.
        let snapshots = try await database.latestSnapshots()
        #expect(snapshots.isEmpty)
    }
}
