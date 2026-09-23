import Testing
import Foundation
import UserNotifications
@testable import SocialBrain

/// `NotificationManager` had zero tests (#90), because every method reached
/// `UNUserNotificationCenter.current()` and running one would have posted a
/// real notification.
///
/// What is worth pinning: the reminder fires when the export goes stale rather
/// than at import time, the identifier is per platform so re-importing
/// replaces its own reminder and nobody else's, and nothing is posted when the
/// user has not granted permission — the likely state on an unsigned build.
@Suite("Notification manager")
struct NotificationManagerTests {

    private func manager(_ center: RecordingNotificationCenter) -> NotificationManager {
        NotificationManager(center: center)
    }

    // MARK: - Stale-export reminders

    @Test("A reminder is scheduled for the day the export goes stale")
    func reminderFiresAtTheStaleDate() async throws {
        // LinkedIn's threshold is three days, so an import today is due a
        // reminder in three days — not now, and not at some fixed hour.
        //
        // Relative to now, not a fixed instant: production takes
        // `max(staleDate, now + 5s)`, so a pinned date silently stops testing
        // the stale date once the wall clock passes it, and the test turns red
        // on its own with nothing changed.
        let center = RecordingNotificationCenter()
        let importedAt = Date()
        await manager(center).scheduleStaleExportReminder(for: .linkedin, lastImportDate: importedAt)

        let request = try #require(center.onlyRequest)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        let expected = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: importedAt.addingTimeInterval(3 * 24 * 3600))
        #expect(trigger.dateComponents == expected)
        // Deliberate today, and wrong: the reminder fires once and is never
        // re-armed, which is #87. That fix changes this assertion.
        #expect(trigger.repeats == false)
    }

    @Test("An export that is already stale is reminded about almost immediately")
    func alreadyStaleFiresSoon() async throws {
        // Not at launch: the fire date is nudged a few seconds out so the
        // notification doesn't land while the app is still starting.
        let center = RecordingNotificationCenter()
        await manager(center).scheduleStaleExportReminder(
            for: .linkedin, lastImportDate: Date(timeIntervalSinceNow: -30 * 24 * 3600))

        let request = try #require(center.onlyRequest)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        let fireDate = try #require(Calendar.current.date(from: trigger.dateComponents))
        #expect(fireDate.timeIntervalSinceNow < 120)
        #expect(fireDate.timeIntervalSinceNow > -120)
    }

    @Test("The reminder names the platform and its threshold")
    func reminderBodyNamesThePlatform() async throws {
        let center = RecordingNotificationCenter()
        await manager(center).scheduleStaleExportReminder(for: .oreilly, lastImportDate: Date())

        let request = try #require(center.onlyRequest)
        #expect(request.content.title.contains("O'Reilly"))
        // O'Reilly's threshold is 30 days, unlike LinkedIn's three.
        #expect(request.content.body.contains("30 days"))
    }

    @Test("Each platform gets its own identifier, so one import does not cancel another")
    func identifiersArePerPlatform() async throws {
        let center = RecordingNotificationCenter()
        let subject = manager(center)
        await subject.scheduleStaleExportReminder(for: .linkedin, lastImportDate: Date())
        await subject.scheduleStaleExportReminder(for: .substack, lastImportDate: Date())

        #expect(center.added.map(\.identifier) == ["stale-export-linkedin", "stale-export-substack"])
    }

    @Test("Cancelling removes that platform's reminder and no other")
    func cancelRemovesOneIdentifier() async throws {
        let center = RecordingNotificationCenter()
        await manager(center).cancelStaleExportReminder(for: .substack)

        #expect(center.removed == ["stale-export-substack"])
        #expect(center.added.isEmpty)
    }

    @Test("Nothing is scheduled when notifications are not authorised")
    func unauthorisedSchedulesNothing() async throws {
        // The likely state on an unsigned, self-built app.
        let center = RecordingNotificationCenter(status: .denied)
        await manager(center).scheduleStaleExportReminder(for: .linkedin, lastImportDate: Date())

        #expect(center.added.isEmpty)
    }

    // MARK: - Spike alerts

    @Test("One spike is reported with its own summary")
    func singleSpikeUsesItsSummary() async throws {
        let center = RecordingNotificationCenter()
        let alert = SpikeAlert(platform: .mastodon, instanceName: "default",
                               metricLabel: "Followers", metricKey: "followers_count",
                               rendering: .percentage, previousValue: 100, currentValue: 130)
        await manager(center).sendSpikeAlerts([alert])

        let request = try #require(center.onlyRequest)
        #expect(request.content.title == "Metric spike detected")
        #expect(request.content.body == alert.summary)
        // Immediate delivery.
        #expect(request.trigger == nil)
    }

    @Test("Several spikes are counted, and the body is capped at three")
    func severalSpikesAreSummarised() async throws {
        let center = RecordingNotificationCenter()
        let alerts = (1...4).map {
            SpikeAlert(platform: .mastodon, instanceName: "default",
                       metricLabel: "Metric \($0)", metricKey: "metric_\($0)",
                       rendering: .percentage, previousValue: 10, currentValue: 20)
        }
        await manager(center).sendSpikeAlerts(alerts)

        let request = try #require(center.onlyRequest)
        #expect(request.content.title == "4 metric spikes detected")
        #expect(request.content.body.split(separator: "\n").count == 3)
        #expect(!request.content.body.contains("Metric 4"))
    }

    @Test("No alerts posts nothing at all")
    func noAlertsPostsNothing() async throws {
        let center = RecordingNotificationCenter()
        await manager(center).sendSpikeAlerts([])

        #expect(center.added.isEmpty)
    }

    @Test("Spikes are not posted when notifications are not authorised")
    func unauthorisedSpikesPostNothing() async throws {
        let center = RecordingNotificationCenter(status: .denied)
        let alert = SpikeAlert(platform: .bluesky, instanceName: "default",
                               metricLabel: "Followers", metricKey: "followers_count",
                               rendering: .percentage, previousValue: 1, currentValue: 2)
        await manager(center).sendSpikeAlerts([alert])

        #expect(center.added.isEmpty)
    }

    // MARK: - Authorization

    @Test("Requesting authorization asks the centre once")
    func requestAuthorizationIsForwarded() async throws {
        let center = RecordingNotificationCenter()
        await manager(center).requestAuthorization()

        #expect(center.authorizationRequests == 1)
    }
}
