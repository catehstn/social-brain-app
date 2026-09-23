import UserNotifications
import Foundation

/// The parts of `UNUserNotificationCenter` this app uses.
///
/// A protocol so tests can watch what would have been scheduled. Without one,
/// `NotificationManager` had no tests at all (#90) and nothing could exercise
/// it without posting real notifications to whoever ran the suite — the same
/// hazard as a test writing real preferences.
///
/// `authorizationStatus` rather than `notificationSettings`: `UNNotificationSettings`
/// is not `Sendable`, so reading the one field here keeps a non-Sendable type
/// from crossing into the actor.
protocol NotificationScheduling: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async
    func add(_ request: UNNotificationRequest) async throws
    func removePending(withIdentifiers identifiers: [String])
}

/// `@unchecked`: `UNUserNotificationCenter` is a singleton whose methods are
/// callable from any thread, and it is not annotated `Sendable`. Apple does
/// not state thread-safety for it as plainly as for `UserDefaults`, so this is
/// the usual assumption about an Objective-C singleton rather than a
/// documented guarantee.
extension UNUserNotificationCenter: @unchecked @retroactive Sendable {}

extension UNUserNotificationCenter: NotificationScheduling {
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    public func requestAuthorization() async {
        // Denial is ignored on purpose: notifications are a convenience.
        _ = try? await requestAuthorization(options: [.alert, .sound])
    }

    public func removePending(withIdentifiers identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Manages `UserNotifications` for the app — primarily stale-export reminders
/// that prompt the user to download and import a fresh file-export from platforms
/// like Substack or O'Reilly.
actor NotificationManager {

    static let shared = NotificationManager(center: UNUserNotificationCenter.current())

    private let center: any NotificationScheduling

    /// No production default: a test constructing one without saying where it
    /// posts would post for real. `SocialBrainApp` and `PlatformsView` pass
    /// `.shared`.
    init(center: any NotificationScheduling) {
        self.center = center
    }

    // MARK: - Authorization

    /// Requests notification permission if not already granted.
    /// Silently ignores denial; notifications are a convenience, not critical.
    func requestAuthorization() async {
        await center.requestAuthorization()
    }

    // MARK: - Stale-export reminders

    /// Schedules (or re-schedules) a stale-export reminder for the given platform.
    ///
    /// Uses the same per-platform thresholds as `StalenessThreshold` in FeedCardBuilder:
    /// LinkedIn and Substack fire after 3 days; O'Reilly after 30 days.
    /// If the stale date has already passed, a notification fires immediately (after a
    /// short delay so the app has finished launching).
    ///
    /// - Parameters:
    ///   - platform: The file-export platform to remind about.
    ///   - lastImportDate: The date of the most recent successful import.
    func scheduleStaleExportReminder(for platform: Platform, lastImportDate: Date) async {
        guard await center.authorizationStatus() == .authorized else { return }

        let thresholdSeconds = StalenessThreshold.threshold(for: platform) ?? (30 * 24 * 3600)
        let thresholdDays = Int(thresholdSeconds / 86400)

        let staleDate = lastImportDate.addingTimeInterval(thresholdSeconds)

        // If already stale, fire after a short delay to avoid interrupting launch.
        let fireDate = max(staleDate, Date(timeIntervalSinceNow: 5))

        let content = UNMutableNotificationContent()
        content.title = "Time to update your \(platform.displayName) data"
        content.body = "It's been over \(thresholdDays) days since your last \(platform.displayName) export. Open Social Brain and import fresh data for an accurate analysis."
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationID(for: platform),
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("[NotificationManager] Could not schedule reminder for \(platform): \(error)")
        }
    }

    /// Cancels any pending stale-export reminder for the given platform.
    /// Call this after a successful import to reset the reminder clock.
    func cancelStaleExportReminder(for platform: Platform) {
        center.removePending(withIdentifiers: [notificationID(for: platform)])
    }

    // MARK: - Spike alerts

    /// Posts an immediate notification summarising spike alerts from a collection run.
    ///
    /// - Parameter alerts: The spike alerts to report. Does nothing when the array is empty.
    func sendSpikeAlerts(_ alerts: [SpikeAlert]) async {
        guard !alerts.isEmpty else { return }
        guard await center.authorizationStatus() == .authorized else {
            // On an unsigned, self-built app this is the likely state, not an
            // edge case. Silence here means a spike detected by the background
            // run is never surfaced and nothing records that it happened. (The
            // Feed still recomputes spike cards on next open, so the user does
            // eventually see it — but not when it mattered.)
            NSLog("Spike alerts not delivered — notifications are not authorised: %@",
                  alerts.map(\.summary).joined(separator: "; "))
            return
        }

        let content = UNMutableNotificationContent()
        if alerts.count == 1 {
            content.title = "Metric spike detected"
            content.body = alerts[0].summary
        } else {
            content.title = "\(alerts.count) metric spikes detected"
            let lines = alerts.prefix(3).map { "• \($0.summary)" }.joined(separator: "\n")
            content.body = lines
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "spike-alert-\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            print("[NotificationManager] Could not send spike alert: \(error)")
        }
    }

    // MARK: - Private

    private func notificationID(for platform: Platform) -> String {
        "stale-export-\(platform.rawValue)"
    }
}
