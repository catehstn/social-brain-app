import SwiftUI

@MainActor
final class FeedViewModel: ObservableObject {

    // cards must be var (not private(set)) so FeedCardView can receive a
    // Binding<FeedCard> via $vm.cards[index] for expand/collapse write-back.
    @Published var cards: [FeedCard] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?

    private let database: AppDatabase
    private let now: () -> Date

    init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            // latestSnapshots() is synchronous within the actor; run it via a
            // detached task so the actor's thread is used without blocking the
            // main actor.
            let snapshots = try await Task.detached(priority: .userInitiated) { [database] in
                try await database.latestSnapshots()
            }.value
            // FeedCardBuilder.build is non-throwing (all JSON decoded with try?)
            cards = FeedCardBuilder.build(snapshots: snapshots, now: now())
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
