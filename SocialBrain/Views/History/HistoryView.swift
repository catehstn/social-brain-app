import SwiftUI

struct HistoryView: View {
    @State private var viewModel: HistoryViewModel

    init(database: AppDatabase) {
        _viewModel = State(wrappedValue: HistoryViewModel(database: database))
    }

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.runs.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Run a collection to see history here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                runList
            }
        }
        .task { await viewModel.load() }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh history")
                .disabled(viewModel.isLoading)
            }
        }
    }

    private var runList: some View {
        List(viewModel.runs) { run in
            runRow(run)
        }
        .listStyle(.inset)
        .refreshable { await viewModel.load() }
    }

    private func runRow(_ run: CollectionRun) -> some View {
        let snaps = run.id.flatMap { viewModel.snapshots[$0] } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dateFmt.string(from: run.startedAt))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                statusBadge(run: run, snapCount: snaps.count)
            }
            if !snaps.isEmpty {
                Text(snaps.map(\.platform).sorted().map { Platform(rawValue: $0)?.displayName ?? $0 }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let completed = run.completedAt {
                let secs = Int(completed.timeIntervalSince(run.startedAt))
                Text("Completed in \(secs)s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(run: CollectionRun, snapCount: Int) -> some View {
        let hasErrors = run.errorCount > 0
        return HStack(spacing: 4) {
            Image(systemName: hasErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(hasErrors ? Color.orange : Color.green)
            Text("\(snapCount) platform\(snapCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasErrors {
                Text("(\(run.errorCount) error\(run.errorCount == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
