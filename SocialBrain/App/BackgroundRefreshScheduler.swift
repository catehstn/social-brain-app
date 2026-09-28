import Foundation

/// The part of `NSBackgroundActivityScheduler` this app uses.
///
/// A protocol so the deferral logic can be tested. Without one,
/// `BackgroundRefreshScheduler` had no tests at all (#90): the only way to
/// exercise it was to register a real activity with the system and wait up to a
/// day for it to fire.
protocol BackgroundActivityScheduling: AnyObject, Sendable {
    /// Whether the system wants the work postponed — thermal pressure, battery,
    /// or the user actively using the machine.
    var shouldDefer: Bool { get }
    /// Named `scheduleActivity` rather than `schedule`: the latter would be
    /// ambiguous with `NSBackgroundActivityScheduler`'s own method inside the
    /// conformance below, and the forwarding call would recurse.
    func scheduleActivity(
        _ block: @escaping @Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void)
    func invalidate()
}

/// `@unchecked`: `NSBackgroundActivityScheduler` is an Objective-C class that is
/// not annotated `Sendable`. Touched only from the app delegate's lifecycle.
extension NSBackgroundActivityScheduler: BackgroundActivityScheduling, @unchecked @retroactive Sendable {
    public func scheduleActivity(
        _ block: @escaping @Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void
    ) {
        schedule { completion in block(completion) }
    }
}

/// Manages the daily analytics auto-refresh using `NSBackgroundActivityScheduler`.
///
/// `NSBackgroundActivityScheduler` is the correct macOS API for background work —
/// `BGTaskScheduler` is iOS-only and not available on native macOS.
///
/// The scheduler fires approximately once per day when the system is idle, giving
/// the app a chance to collect fresh analytics from all configured API platforms.
/// File-export platforms (Substack, O'Reilly) cannot be refreshed automatically
/// because they require the user to download the export manually.
final class BackgroundRefreshScheduler: NSObject, @unchecked Sendable {

    static let shared = BackgroundRefreshScheduler(
        activity: BackgroundRefreshScheduler.makeSystemActivity())

    private let activity: any BackgroundActivityScheduling

    /// No production default: a test constructing one without saying where it
    /// schedules would register a real activity with the system.
    init(activity: any BackgroundActivityScheduling) {
        self.activity = activity
        super.init()
    }

    /// The real one, configured for a daily wake.
    ///
    /// A factory rather than an initialiser body so a test can assert the
    /// cadence — an interval quietly changed from a day to an hour, or to a
    /// week, looks like nothing in a diff and cannot be noticed at runtime for
    /// a day at best.
    static func makeSystemActivity() -> NSBackgroundActivityScheduler {
        let activity = NSBackgroundActivityScheduler(
            identifier: "com.catehuston.SocialBrain.refresh"
        )
        activity.repeats = true
        activity.interval = 24 * 60 * 60   // Every ~24 hours
        activity.tolerance = 4  * 60 * 60  // ±4-hour window
        activity.qualityOfService = .background
        return activity
    }

    // MARK: - Public API

    /// Starts the background scheduler.  The supplied `handler` is called once
    /// per day when the system chooses to wake the app.
    ///
    /// Call once from `applicationDidFinishLaunching`.
    func start(handler: @Sendable @escaping () async -> Void) {
        activity.scheduleActivity { [weak self] completion in
            // `shouldDefer` is read at wake time, not at schedule time: the
            // system sets it when it wants the work postponed, and reporting
            // `.deferred` is what makes it ask again later. Running the
            // collection anyway would be a network burst on a machine the
            // system has just said is busy or hot.
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
