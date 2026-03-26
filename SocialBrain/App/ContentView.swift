import SwiftUI

struct ContentView: View {
    let database: AppDatabase

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selection: SidebarItem = .run

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
                Label(item.label, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            switch selection {
            case .run:
                RunView(database: database)
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

// MARK: - Sidebar items

private enum SidebarItem: String, CaseIterable {
    case run
    case dashboard
    case history
    case platforms

    var label: String {
        switch self {
        case .run:       "Run"
        case .dashboard: "Dashboard"
        case .history:   "History"
        case .platforms: "Platforms"
        }
    }

    var icon: String {
        switch self {
        case .run:       "play.circle"
        case .dashboard: "chart.line.uptrend.xyaxis"
        case .history:   "clock.arrow.circlepath"
        case .platforms: "square.grid.2x2"
        }
    }
}

#Preview {
    ContentView(database: try! AppDatabase.makeInMemory())
}
