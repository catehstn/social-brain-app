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
    private let visibility: PlatformVisibilityStore
    private let goals: AnalyticsGoalStore
    private var lastSince: Date = .distantPast

    init(database: AppDatabase,
         visibility: PlatformVisibilityStore = .shared,
         goals: AnalyticsGoalStore = .shared) {
        self.database = database
        self.engine = CollectionEngine(database: database)
        self.assembler = PromptAssembler(labels: .shared)
        self.visibility = visibility
        self.goals = goals
    }

    // MARK: - Actions

    /// - Parameter since: the start of the window. `.distantPast` means as far
    ///   back as each platform allows; there is no longer a `nil` that means
    ///   something different per collector (#96).
    func startCollection(since: Date) async {
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
                    try KeychainStore.shared.load(for: instance)
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
        await SpikeNotifier(database: database).notifySpikes(for: summary)

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
            $0.authType == .fileExport && KeychainStore.shared.hasCredentials(for: $0)
        }
        for platform in fileExportPlatforms {
            let inst = PlatformInstance(platform: platform)
            guard snapshotsByInstance[inst] == nil else { continue }
            if let snap = try? await database.latestSnapshot(for: platform) {
                snapshotsByInstance[inst] = snap
            }
        }

        // Hidden platforms are dropped here rather than earlier: collection
        // still runs and still records history, so unhiding a platform does not
        // leave a gap in its series. What hiding means is "don't put this in
        // front of me", and the prompt is the largest place it was ignored —
        // a hidden platform was still being sent to Claude (#80).
        let visibleSnapshots = visibility.visible(snapshotsByInstance)

        guard !visibleSnapshots.isEmpty else { return }

        let input = PromptAssembler.Input(
            periodLabel: Self.periodLabel(since: lastSince),
            reportDate: summary.completedAt,
            snapshots: visibleSnapshots,
            goal: goals.current,
            goalCustomText: goals.customText
        )
        generatedPrompt = assembler.assemble(input)
    }

    /// The prompt header's period line.
    ///
    /// Static and non-private so it can be tested: `RunViewModel` has no test
    /// coverage, and this is a pure function of a date that had a user-visible
    /// bug in it (#96).
    nonisolated static func periodLabel(since: Date) -> String {
        // `.distantPast` is the All time button. This used to arrive as nil and
        // the guard caught it; once `since` became non-optional the branch went
        // dead and the header read "Last 739879 days" (#96).
        guard since != .distantPast else { return "All time" }
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
