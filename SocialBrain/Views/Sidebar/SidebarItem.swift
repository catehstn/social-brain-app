import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case run
    case feed        // between run and dashboard
    case dashboard
    case history
    case platforms

    var id: String { rawValue }

    var label: String {
        switch self {
        case .run:       return "Run"
        case .feed:      return "Feed"
        case .dashboard: return "Dashboard"
        case .history:   return "History"
        case .platforms: return "Platforms"
        }
    }

    var icon: String {
        switch self {
        case .run:       return "play.circle"
        case .feed:      return "rectangle.stack"
        case .dashboard: return "chart.line.uptrend.xyaxis"
        case .history:   return "clock.arrow.circlepath"
        case .platforms: return "square.grid.2x2"
        }
    }
}
