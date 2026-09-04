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
    private let databaseResult: Result<AppDatabase, any Error> = Result {
        try AppDatabase.makeDefault()
    }

    var body: some Scene {
        WindowGroup {
            switch databaseResult {
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

        // Start the daily background refresh for API-based platforms.
        BackgroundRefreshScheduler.shared.start {
            // Run without a date filter so the background task always fetches
            // the latest state regardless of the user's last manual run.
            let collectors = CollectorRegistry.configured()
                .filter { $0.platform.authType == .apiKey || $0.platform.authType == .oauthToken }
            guard !collectors.isEmpty else { return }
            let engine: CollectionEngine
            do {
                let db = try AppDatabase.makeDefault()
                engine = CollectionEngine(database: db)
            } catch {
                return
            }
            _ = try? await engine.run(
                collectors: collectors,
                credentials: { platform in try KeychainStore.shared.load(for: platform) },
                since: nil,
                progress: { _ in }
            )
        }
    }
}
