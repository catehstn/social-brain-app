import SwiftUI

// MARK: - State

enum RunState: Sendable {
    case idle
    case running(completed: Int, total: Int)
    case finished(CollectionSummary)
    case failed(Error)
}

// MARK: - ViewModel

/// Drives the Run view: triggers a collection, tracks progress, and surfaces
/// the finished prompt for copying to Claude.
@Observable
@MainActor
final class RunViewModel {
    var state: RunState = .idle
    var completedPlatforms: [CollectionResult] = []
    var generatedPrompt: String?

    private let database: AppDatabase
    private let engine: CollectionEngine
    private let assembler: PromptAssembler
    private var lastSince: Date?

    init(database: AppDatabase) {
        self.database = database
        self.engine = CollectionEngine(database: database)
        self.assembler = PromptAssembler()
    }

    // MARK: - Actions

    func startCollection(since: Date? = nil) async {
        let collectors = CollectorRegistry.configured()
        guard !collectors.isEmpty else {
            state = .idle
            return
        }

        state = .running(completed: 0, total: collectors.count)
        completedPlatforms = []
        generatedPrompt = nil
        lastSince = since

        do {
            let summary = try await engine.run(
                collectors: collectors,
                credentials: { instance in
                    try KeychainStore.load(for: instance)
                },
                since: since,
                progress: { [weak self] result in
                    await self?.handleProgress(result, total: collectors.count)
                }
            )
            await finishCollection(summary: summary)
        } catch {
            state = .failed(error)
        }
    }

    // MARK: - Private

    private func handleProgress(_ result: CollectionResult, total: Int) async {
        completedPlatforms.append(result)
        state = .running(completed: completedPlatforms.count, total: total)
    }

    private func finishCollection(summary: CollectionSummary) async {
        state = .finished(summary)

        // Detect spikes — compare the latest two snapshots for each platform
        // that succeeded in this run and fire a notification if anything is notable.
        await detectAndNotifySpikes(for: summary)

        // Build a [PlatformInstance: PlatformSnapshot] dictionary from successful results.
        var snapshotsByInstance: [PlatformInstance: PlatformSnapshot] = [:]
        for data in summary.results.compactMap(\.platformData) {
            let inst = PlatformInstance(platform: data.platform, instanceName: data.instanceName)
            if let snap = try? await database.latestSnapshot(for: data.platform,
                                                              instanceName: data.instanceName) {
                snapshotsByInstance[inst] = snap
            }
        }

        // Also pull in the most recent snapshot for each configured file-export
        // platform (default instance only).  These aren't fetched live — the user
        // imports them manually — but they should still appear in the prompt.
        let fileExportPlatforms = Platform.allCases.filter {
            $0.authType == .fileExport && KeychainStore.hasCredentials(for: $0)
        }
        for platform in fileExportPlatforms {
            let inst = PlatformInstance(platform: platform)
            guard snapshotsByInstance[inst] == nil else { continue }
            if let snap = try? await database.latestSnapshot(for: platform) {
                snapshotsByInstance[inst] = snap
            }
        }

        guard !snapshotsByInstance.isEmpty else { return }

        let input = PromptAssembler.Input(
            periodLabel: periodLabel(since: lastSince),
            reportDate: summary.completedAt,
            snapshots: snapshotsByInstance,
            goal: AnalyticsGoal.current,
            goalCustomText: AnalyticsGoal.customText
        )
        generatedPrompt = assembler.assemble(input)
    }

    private func detectAndNotifySpikes(for summary: CollectionSummary) async {
        let detector = SpikeDetector()
        var allAlerts: [SpikeAlert] = []

        let successfulInstances: [PlatformInstance] = summary.results.compactMap { result in
            guard let data = result.platformData else { return nil }
            return PlatformInstance(platform: data.platform, instanceName: data.instanceName)
        }
        for instance in successfulInstances {
            guard let pair = try? await database.twoLatestSnapshots(
                for: instance.platform, instanceName: instance.instanceName),
                  pair.count == 2 else { continue }
            let alerts = detector.detect(current: pair[0], previous: pair[1])
            allAlerts.append(contentsOf: alerts)
        }

        if !allAlerts.isEmpty {
            await NotificationManager.shared.sendSpikeAlerts(allAlerts)
        }
    }

    private func periodLabel(since: Date?) -> String {
        guard let since else { return "All time" }
        let days = Int(Date().timeIntervalSince(since) / 86400)
        switch days {
        case 0...1:   return "Last 24 hours"
        case 2...8:   return "Last 7 days"
        case 9...31:  return "Last 30 days"
        case 32...92: return "Last 90 days"
        default:      return "Last \(days) days"
        }
    }
}
