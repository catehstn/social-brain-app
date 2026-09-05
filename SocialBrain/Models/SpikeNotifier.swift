/// Detects metric spikes from a finished collection run and notifies the user.
///
/// Extracted from `RunViewModel` because the background refresh never ran it.
/// That made the scheduled run — the one that happens when nobody is watching,
/// and the only reason notifications exist at all — the single path that could
/// never produce one. The design brief's "mid-week spike wakes me up" flow could
/// not happen: spikes were only ever detected while the user was already looking
/// at the Run screen, having just pressed the button.
struct SpikeNotifier: Sendable {

    /// Injectable so tests don't post real system notifications.
    typealias Send = @Sendable ([SpikeAlert]) async -> Void

    private let database: AppDatabase
    private let detector: SpikeDetector
    private let send: Send

    init(
        database: AppDatabase,
        detector: SpikeDetector = SpikeDetector(),
        send: @escaping Send = { await NotificationManager.shared.sendSpikeAlerts($0) }
    ) {
        self.database = database
        self.detector = detector
        self.send = send
    }

    /// Compares the two most recent snapshots for every platform that succeeded
    /// in this run, and sends one notification covering all the alerts found.
    ///
    /// - Returns: the alerts, so callers and tests can inspect them without
    ///   intercepting the notification.
    @discardableResult
    func notifySpikes(for summary: CollectionSummary) async -> [SpikeAlert] {
        var alerts: [SpikeAlert] = []

        let successfulInstances: [PlatformInstance] = summary.results.compactMap { result in
            guard let data = result.platformData else { return nil }
            return PlatformInstance(platform: data.platform, instanceName: data.instanceName)
        }

        for instance in successfulInstances {
            guard let pair = try? await database.twoLatestSnapshots(
                for: instance.platform, instanceName: instance.instanceName),
                  pair.count == 2 else { continue }
            alerts.append(contentsOf: detector.detect(current: pair[0], previous: pair[1]))
        }

        if !alerts.isEmpty {
            await send(alerts)
        }
        return alerts
    }
}
