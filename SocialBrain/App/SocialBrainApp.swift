import SwiftUI

@main
struct SocialBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Shared database, opened once at app launch.
    ///
    /// Held as a `Result` rather than force-unwrapped: this used to `fatalError`,
    /// which meant a database that could not be opened produced "SocialBrain quit
    /// unexpectedly" with the reason only in a crash report — on an unsigned app
    /// with no crash reporting. Schema drift is now a real, reachable failure
    /// (see `AppDatabaseError.schemaChanged`), so the reason has to be visible.
    /// Static so the delegate and the background-refresh closure read the same
    /// value rather than opening the file again. `AppDatabase.init` is not a
    /// cheap liveness check — `hasSchemaChanges` builds a temporary database,
    /// re-runs every migration into it and diffs both schemas — and two
    /// `DatabasePool` instances on one file is something GRDB warns against.
    static let databaseResult: Result<AppDatabase, any Error> = Result {
        try AppDatabase.makeDefault()
    }

    var body: some Scene {
        WindowGroup {
            switch Self.databaseResult {
            case .success(let database):
                ContentView(database: database)
            case .failure(let error):
                DatabaseUnavailableView(error: error)
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

/// Handles lifecycle events that SwiftUI's App protocol doesn't expose directly.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When the process is a test host, close all windows immediately.
        // This prevents macOS window-state restoration from blocking the
        // XCTest runner's connection to the test daemon.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApplication.shared.windows.forEach { $0.close() }
            return
        }

        // UI test support: reset all hidden-platform state when requested.
        if ProcessInfo.processInfo.arguments.contains("-resetHiddenPlatforms") {
            PlatformVisibilityStore.shared.resetAll()
        }

        // Request notification permission (non-blocking; silently ignored if denied).
        Task { await NotificationManager.shared.requestAuthorization() }

        // Don't schedule a daily refresh against a database that can't be
        // opened. The closure below would fail and return into an empty catch
        // once a day forever — a swallowed error of exactly the kind this app
        // already has too many of. Reading the same Result the window switches
        // on makes "the user is looking at DatabaseUnavailableView" a guarantee
        // rather than an inference from two independent opens agreeing.
        let database: AppDatabase
        switch SocialBrainApp.databaseResult {
        case .success(let db):
            database = db
        case .failure(let error):
            NSLog("Skipping background refresh: %@", error.localizedDescription)
            return
        }

        // Start the daily background refresh for API-based platforms.
        BackgroundRefreshScheduler.shared.start {
            await Self.runBackgroundRefresh(database: database)
        }
    }

    /// One scheduled refresh.
    ///
    /// A named function rather than an inline closure so it can be tested. As a
    /// closure, deleting the `notifySpikes` call below left every test passing —
    /// the one behaviour this exists to provide had no regression guard at all.
    ///
    /// - Parameters:
    ///   - collectors: defaults to the configured API-backed platforms.
    ///   - notifier: defaults to the real one, which posts a system notification.
    static func runBackgroundRefresh(
        database: AppDatabase,
        collectors: [any Collector]? = nil,
        credentials: (@Sendable (PlatformInstance) throws -> Credentials?)? = nil,
        notifier: SpikeNotifier? = nil
    ) async {
        // Run without a date filter so the background task always fetches the
        // latest state regardless of the user's last manual run.
        let collectors = collectors ?? CollectorRegistry.configured()
            .filter { $0.platform.authType == .apiKey || $0.platform.authType == .oauthToken }
        guard !collectors.isEmpty else { return }

        let engine = CollectionEngine(database: database)
        let summary: CollectionSummary
        do {
            summary = try await engine.run(
                collectors: collectors,
                credentials: credentials ?? { instance in
                    try KeychainStore.shared.load(for: instance)
                },
                since: nil,
                progress: { _ in }
            )
        } catch {
            // Was a bare `try?`. An unattended path that fails silently once a
            // day forever is the failure mode this app already has too much of.
            NSLog("Background refresh failed: %@", error.localizedDescription)
            return
        }

        // The whole point of a background run: this is the path that can
        // actually surprise the user, and it was the one path that never
        // detected a spike or sent a notification.
        await (notifier ?? SpikeNotifier(database: database)).notifySpikes(for: summary)
    }
}
