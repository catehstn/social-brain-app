import SwiftUI

struct ContentView: View {
    let database: AppDatabase

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selection: SidebarItem = .run
    @State private var dashboardInitialPlatform: Platform = .mastodon  // kept for FeedView navigation

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
                Label(item.label, systemImage: item.icon)
                    .tag(item)
                    .accessibilityIdentifier("sidebar_\(item.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                GoalBadgeView()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        } detail: {
            switch selection {
            case .run:
                RunView(database: database)
            case .feed:
                FeedView(database: database) { newSelection, platform in
                    if let platform {
                        dashboardInitialPlatform = platform
                    }
                    selection = newSelection
                }
            case .dashboard:
                DashboardView(database: database)
            case .history:
                HistoryView(database: database)
            case .platforms:
                PlatformsView(database: database)
            }
        }
        .navigationTitle("Social Brain")
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView { hasCompletedOnboarding = true }
        }
    }
}

#Preview {
    ContentView(database: try! AppDatabase.makeInMemory())
}
