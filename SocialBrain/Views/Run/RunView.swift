import SwiftUI

struct RunView: View {
    @State private var viewModel: RunViewModel
    @State private var showingPrompt = false
    @State private var since: Date = Calendar.current.date(byAdding: .day, value: -30, to: .now)!

    init(database: AppDatabase) {
        _viewModel = State(wrappedValue: RunViewModel(database: database))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingPrompt) {
            if let prompt = viewModel.generatedPrompt {
                PromptSheet(prompt: prompt)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collect Analytics")
                    .font(.headline)
                Text("Fetch data from all configured platforms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sinceMenu
            runButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sinceMenu: some View {
        Menu {
            Button("Last 7 days")  { since = Calendar.current.date(byAdding: .day, value: -7,  to: .now)! }
            Button("Last 30 days") { since = Calendar.current.date(byAdding: .day, value: -30, to: .now)! }
            Button("Last 90 days") { since = Calendar.current.date(byAdding: .day, value: -90, to: .now)! }
            Button("All time")     { since = .distantPast }
        } label: {
            Label(sinceLabel, systemImage: "calendar")
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .disabled(isRunning)
    }

    private var sinceLabel: String {
        let days = Int(Date().timeIntervalSince(since) / 86400)
        switch days {
        case 0..<8:   return "7 days"
        case 8..<31:  return "30 days"
        case 31..<91: return "90 days"
        default:      return "All time"
        }
    }

    private var runButton: some View {
        Button {
            Task { await viewModel.startCollection(since: since == .distantPast ? nil : since) }
        } label: {
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Label("Run", systemImage: "play.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = viewModel.state { return true }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            idlePlaceholder
        case .running(let completed, let total):
            runningView(completed: completed, total: total)
        case .finished(let summary):
            finishedView(summary: summary)
        case .failed(let error):
            errorView(error: error)
        }
    }

    private var idlePlaceholder: some View {
        let hasPlatforms = !CollectorRegistry.configured().isEmpty
        return ContentUnavailableView(
            hasPlatforms ? "Ready to collect" : "No platforms configured",
            systemImage: hasPlatforms ? "chart.bar.doc.horizontal" : "square.grid.2x2",
            description: Text(hasPlatforms
                ? "Press Run to fetch analytics from all configured platforms."
                : "Open Platforms in the sidebar to add credentials for your analytics platforms.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runningView(completed: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(completed), total: Double(total))
                .padding(.horizontal)
            Text("\(completed) / \(total) platforms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            platformResultList
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func finishedView(summary: CollectionSummary) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                statBadge(label: "Platforms", value: "\(summary.successCount)", color: .green)
                if summary.errorCount > 0 {
                    statBadge(label: "Errors", value: "\(summary.errorCount)", color: .red)
                }
            }
            platformResultList
            if viewModel.generatedPrompt != nil {
                Button {
                    showingPrompt = true
                } label: {
                    Label("View Prompt for Claude", systemImage: "sparkles")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func errorView(error: Error) -> some View {
        ContentUnavailableView(
            "Collection failed",
            systemImage: "exclamationmark.triangle",
            description: Text(error.localizedDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var platformResultList: some View {
        List(viewModel.completedPlatforms, id: \.instance.id) { result in
            HStack {
                Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.isSuccess ? .green : .red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.platform.displayName)
                    if let subtitle = instanceSubtitle(for: result.instance) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let error = result.error {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: 260)
    }

    private func instanceSubtitle(for instance: PlatformInstance) -> String? {
        if let label = InstanceLabels.label(for: instance) { return label }
        if instance.instanceName != "default" { return instance.instanceName }
        return nil
    }

    private func statBadge(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.largeTitle.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Prompt sheet

private struct PromptSheet: View {
    let prompt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Analytics Prompt")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            ScrollView {
                Text(prompt)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 700, height: 520)
    }
}
