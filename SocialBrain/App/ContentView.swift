import SwiftUI

struct ContentView: View {
    let database: AppDatabase

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
            }
        }
        .navigationTitle("Social Brain")
    }
}

// MARK: - Sidebar items

private enum SidebarItem: String, CaseIterable {
    case run

    var label: String {
        switch self { case .run: "Run" }
    }
    var icon: String {
        switch self { case .run: "play.circle" }
    }
}

#Preview {
    ContentView(database: try! AppDatabase.makeInMemory())
}
