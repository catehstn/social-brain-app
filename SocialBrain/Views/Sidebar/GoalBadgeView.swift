import SwiftUI

/// A small badge at the bottom of the sidebar showing the user's current goal.
struct GoalBadgeView: View {
    @AppStorage("analyticsGoal") private var goalRaw: String = AnalyticsGoal.growReach.rawValue
    @AppStorage("analyticsGoalCustomText") private var goalCustomText: String = ""

    private var label: String {
        guard let goal = AnalyticsGoal(rawValue: goalRaw) else { return "—" }
        if goal == .other, !goalCustomText.isEmpty { return goalCustomText }
        return goal.displayName
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "target")
                .font(.caption2)
                .foregroundStyle(.tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
