import SwiftUI

struct FeedView: View {
    @State private var vm: FeedViewModel
    var onNavigate: (SidebarItem, Platform?) -> Void

    init(database: AppDatabase, onNavigate: @escaping (SidebarItem, Platform?) -> Void) {
        _vm = State(wrappedValue: FeedViewModel(database: database))
        self.onNavigate = onNavigate
    }

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.cards.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "rectangle.stack",
                    description: Text("Run a collection to populate your feed.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Use index-based ForEach so we can pass Binding<FeedCard>
                        // to FeedCardView, allowing expand state to write back into
                        // vm.cards rather than a disconnected local copy.
                        ForEach(vm.cards.indices, id: \.self) { index in
                            FeedCardView(card: $vm.cards[index])
                                .onTapGesture {
                                    onNavigate(.dashboard, vm.cards[index].navigationTarget)
                                }
                                .accessibilityIdentifier("feedCard_\(vm.cards[index].id)")
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("Feed")
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }
}
