import Foundation

/// Manages the daily analytics auto-refresh using `NSBackgroundActivityScheduler`.
///
/// `NSBackgroundActivityScheduler` is the correct macOS API for background work —
/// `BGTaskScheduler` is iOS-only and not available on native macOS.
///
/// The scheduler fires approximately once per day when the system is idle, giving
/// the app a chance to collect fresh analytics from all configured API platforms.
/// File-export platforms (Substack, Amazon KDP) cannot be refreshed automatically
/// because they require the user to download the export manually.
final class BackgroundRefreshScheduler: NSObject, @unchecked Sendable {

    static let shared = BackgroundRefreshScheduler()

    // NSBackgroundActivityScheduler is an ObjC class — not Sendable by default.
    // We use @unchecked Sendable on the enclosing class because the activity is
    // only accessed from the main thread (app delegate lifecycle).
    private let activity: NSBackgroundActivityScheduler

    private override init() {
        activity = NSBackgroundActivityScheduler(
            identifier: "com.catehuston.SocialBrain.refresh"
        )
        activity.repeats = true
        activity.interval = 24 * 60 * 60   // Every ~24 hours
        activity.tolerance = 4  * 60 * 60  // ±4-hour window
        activity.qualityOfService = .background
        super.init()
    }

    // MARK: - Public API

    /// Starts the background scheduler.  The supplied `handler` is called once
    /// per day when the system chooses to wake the app.
    ///
    /// Call once from `applicationDidFinishLaunching`.
    func start(handler: @Sendable @escaping () async -> Void) {
        activity.schedule { [weak self] completion in
            guard let self, !self.activity.shouldDefer else {
                completion(.deferred)
                return
            }
            Task {
                await handler()
                completion(.finished)
            }
        }
    }

    /// Stops the background scheduler (e.g. when the user disables auto-refresh).
    func stop() {
        activity.invalidate()
    }
}
