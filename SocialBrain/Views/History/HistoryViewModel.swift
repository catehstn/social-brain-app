import SwiftUI

@Observable
@MainActor
final class HistoryViewModel {
    var runs: [CollectionRun] = []
    var snapshots: [Int64: [PlatformSnapshot]] = [:]  // runID → snapshots
    var isLoading = false

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            runs = try await database.allRuns()
            // Load snapshots for each run concurrently
            await withTaskGroup(of: (Int64, [PlatformSnapshot]).self) { group in
                for run in runs {
                    guard let id = run.id else { continue }
                    group.addTask {
                        let snaps = (try? await self.database.snapshots(forRunID: id)) ?? []
                        return (id, snaps)
                    }
                }
                for await (id, snaps) in group {
                    snapshots[id] = snaps
                }
            }
        } catch {
            // Silently ignore — empty state is shown
        }
    }
}
