import UserNotifications
import Foundation

/// Manages `UserNotifications` for the app — primarily stale-export reminders
/// that prompt the user to download and import a fresh file-export from platforms
/// like Amazon KDP or Substack.
actor NotificationManager {

    static let shared = NotificationManager()

    // MARK: - Authorization

    /// Requests notification permission if not already granted.
    /// Silently ignores denial; notifications are a convenience, not critical.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Stale-export reminders

    /// Schedules (or re-schedules) a stale-export reminder for the given platform.
    ///
    /// Uses the same per-platform thresholds as `StalenessThreshold` in FeedCardBuilder:
    /// LinkedIn and Substack fire after 3 days; Amazon KDP and O'Reilly after 30 days.
    /// If the stale date has already passed, a notification fires immediately (after a
    /// short delay so the app has finished launching).
    ///
    /// - Parameters:
    ///   - platform: The file-export platform to remind about.
    ///   - lastImportDate: The date of the most recent successful import.
    func scheduleStaleExportReminder(for platform: Platform, lastImportDate: Date) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

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
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[NotificationManager] Could not schedule reminder for \(platform): \(error)")
        }
    }

    /// Cancels any pending stale-export reminder for the given platform.
    /// Call this after a successful import to reset the reminder clock.
    func cancelStaleExportReminder(for platform: Platform) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID(for: platform)])
    }

    // MARK: - Spike alerts

    /// Posts an immediate notification summarising spike alerts from a collection run.
    ///
    /// - Parameter alerts: The spike alerts to report. Does nothing when the array is empty.
    func sendSpikeAlerts(_ alerts: [SpikeAlert]) async {
        guard !alerts.isEmpty else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

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
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[NotificationManager] Could not send spike alert: \(error)")
        }
    }

    // MARK: - Private

    private func notificationID(for platform: Platform) -> String {
        "stale-export-\(platform.rawValue)"
    }
}
