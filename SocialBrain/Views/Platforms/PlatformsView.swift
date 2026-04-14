import SwiftUI
import UniformTypeIdentifiers

struct PlatformsView: View {
    let database: AppDatabase
    @State private var viewModel: PlatformsViewModel
    @State private var showingHidden = false
    @State private var dropTargeted = false
    @State private var dropErrorMessage: String?

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
        .alert("Import Error", isPresented: Binding(
            get: { dropErrorMessage != nil },
            set: { if !$0 { dropErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { dropErrorMessage = nil }
        } message: {
            if let msg = dropErrorMessage { Text(msg) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 10)))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.largeTitle)
                            Text("Drop to import")
                                .font(.headline)
                        }
                        .foregroundStyle(Color.accentColor)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        do {
                            try await viewModel.handleDroppedFile(at: url)
                        } catch ImportError.cancelled {
                            // no-op
                        } catch {
                            dropErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
            return true
        }
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
