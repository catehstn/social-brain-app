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
                credentials: { platform in
                    try KeychainStore.load(for: platform)
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

        // Build the prompt from the successful snapshots.
        let successfulData = summary.results.compactMap(\.platformData)
        guard !successfulData.isEmpty else { return }

        let input = PromptAssembler.Input(
            periodLabel: periodLabel(since: lastSince),
            reportDate: summary.completedAt,
            snapshots: successfulData
        )
        generatedPrompt = assembler.assemble(input)
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
