import SwiftUI

@main
struct SocialBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Shared database, created once at app launch.
    private let database: AppDatabase = {
        do {
            return try AppDatabase.makeDefault()
        } catch {
            // Fatal: can't proceed without a database.
            fatalError("Failed to open database: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(database: database)
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
                credentials: { platform in try KeychainStore.load(for: platform) },
                since: nil,
                progress: { _ in }
            )
        }
    }
}
