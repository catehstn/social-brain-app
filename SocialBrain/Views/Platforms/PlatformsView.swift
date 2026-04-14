import SwiftUI

struct PlatformsView: View {
    let database: AppDatabase
    @State private var viewModel: PlatformsViewModel
    @State private var showingHidden = false

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(wrappedValue: PlatformsViewModel(database: database))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(visiblePlatforms) { platform in
                        NavigationLink(value: platform) {
                            PlatformCard(platform: platform, viewModel: viewModel)
                        }
                        .buttonStyle(.plain)
                    }
                    if showingHidden {
                        ForEach(hiddenPlatforms) { platform in
                            PlatformCard(platform: platform, viewModel: viewModel, isHiddenCard: true)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Platforms")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingHidden.toggle()
                    } label: {
                        Label(
                            showingHidden ? "Hide dismissed" : "Show dismissed",
                            systemImage: showingHidden ? "eye.slash.fill" : "eye.slash"
                        )
                    }
                    .opacity(hiddenPlatforms.isEmpty ? 0 : 1)
                }
            }
            .navigationDestination(for: Platform.self) { platform in
                PlatformDetailView(platform: platform, viewModel: viewModel)
            }
        }
        .onAppear { viewModel.reload() }
    }

    private var visiblePlatforms: [Platform] {
        Platform.allCases.filter { !viewModel.isHidden($0) }
    }

    private var hiddenPlatforms: [Platform] {
        Platform.allCases.filter { viewModel.isHidden($0) }
    }
}

#Preview {
    PlatformsView(database: try! AppDatabase.makeInMemory())
}
