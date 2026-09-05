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
// Serialized: several of these open a DatabasePool on the same throwaway path,
// and GRDB warns against two pools on one file.
@Suite("Database location", .serialized)
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

        // (A `!contains || hasPrefix` assertion used to sit here; it could not
        // fail without the next line failing too, so it tested nothing.)
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!url.path.contains("Application Support"))
        #expect(url.lastPathComponent == "analytics.sqlite")
    }

    @Test("The path is scoped to this process, so concurrent runs cannot collide")
    func pathIsProcessScoped() throws {
        let url = try AppDatabase.defaultDatabaseURL()
        #expect(url.path.contains("SocialBrainTests-\(ProcessInfo.processInfo.processIdentifier)"))
    }

    // A test watching the real store's mtimes used to sit here. It could not
    // discriminate: GRDB opening an already-migrated database writes nothing, so
    // the timestamps are unchanged whether the isolation works or not — it
    // passed with the fix reverted. The structural assertions above are what
    // actually pin this; measured, they catch a revert where the mtime check
    // did not.


    @Test("The throwaway database is usable, migrated, and is the file being written")
    func throwawayDatabaseWorks() async throws {
        let database = try AppDatabase.makeDefault()
        // Reaching a real query proves migrations ran...
        let snapshots = try await database.latestSnapshots()
        #expect(snapshots.isEmpty)

        // ...but an empty result is also what the real (empty) store returns, so
        // assert the file that exists is the throwaway one.
        let url = try AppDatabase.defaultDatabaseURL()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("A UI-test launch argument also selects the throwaway database")
    func uiTestArgumentIsRecognised() {
        // UI tests launch the app as a separate process with no
        // XCTestConfigurationFilePath, so the argument is the only signal.
        // The UI test targets hard-code this string, because importing the app
        // module into a UI test target pulls in GRDB, which they do not link.
        // This assertion is what keeps the two spellings in step.
        #expect(AppDatabase.uiTestLaunchArgument == "-useThrowawayDatabase")
        #expect(ProcessInfo.processInfo.arguments.contains(AppDatabase.uiTestLaunchArgument)
                || AppDatabase.isRunningUnderTest)
    }
}
