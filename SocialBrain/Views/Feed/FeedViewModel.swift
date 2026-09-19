import SwiftUI
import Observation

@MainActor
@Observable
final class FeedViewModel {

    // cards must be var (not private(set)) so FeedCardView can receive a
    // Binding<FeedCard> via $vm.cards[index] for expand/collapse write-back.
    var cards: [FeedCard] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    private let database: AppDatabase
    private let now: () -> Date
    private let visibility: PlatformVisibilityStore

    init(database: AppDatabase,
         now: @escaping @Sendable () -> Date = { Date() },
         visibility: PlatformVisibilityStore = .shared) {
        self.database = database
        self.now = now
        self.visibility = visibility
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            // await hops to the AppDatabase actor's executor, freeing MainActor.
            async let snapshotsTask = database.latestSnapshots()
            async let previousTask  = database.previousSnapshots()
            let (snapshots, previous) = try await (snapshotsTask, previousTask)
            // FeedCardBuilder.build is non-throwing (all JSON decoded with try?)
            cards = FeedCardBuilder.build(snapshots: snapshots,
                                          previousSnapshots: previous,
                                          now: now(),
                                          visibility: visibility)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
