import SwiftUI
import Charts

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel

    // Platforms that have API collectors and can produce chart data
    private let chartablePlatforms: [Platform] = [
        .mastodon, .bluesky, .buttondown, .goatCounter, .vercel, .calendly
    ]

    init(database: AppDatabase) {
        _viewModel = State(wrappedValue: DashboardViewModel(database: database))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await viewModel.load() }
        .onChange(of: viewModel.selectedPlatform) { _, _ in
            Task { await viewModel.load() }
        }
        .onChange(of: viewModel.timeRange) { _, _ in
            Task { await viewModel.load() }
        }
        .navigationTitle("Dashboard")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Picker("Platform", selection: $viewModel.selectedPlatform) {
                ForEach(chartablePlatforms) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .labelsHidden()
            .frame(width: 160)

            Picker("Range", selection: $viewModel.timeRange) {
                ForEach(DashboardViewModel.TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.series.isEmpty {
            ContentUnavailableView(
                "No data for this range",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("Run a collection first, then check back here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(viewModel.series) { series in
                        MetricChartView(series: series)
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Single metric chart

private struct MetricChartView: View {
    let series: MetricSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(series.label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            if series.points.count == 1 {
                // Single data point — just show the value
                Text(formattedValue(series.points[0].value))
                    .font(.title2.bold())
            } else {
                Chart(series.points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(series.label, point.value)
                    )
                    .foregroundStyle(Color.accentColor)
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value(series.label, point.value)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.1))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 120)
            }

            if let last = series.points.last, let prev = series.points.dropLast().last {
                deltaLabel(current: last.value, previous: prev.value)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formattedValue(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.1fK", v / 1_000) }
        if v < 1          { return String(format: "%.1f%%", v * 100) }
        return NumberFormatter.localizedString(from: NSNumber(value: Int(v)), number: .decimal)
    }

    @ViewBuilder
    private func deltaLabel(current: Double, previous: Double) -> some View {
        if previous == 0 { EmptyView() } else {
            let delta = current - previous
            let pct   = (delta / previous) * 100
            let up    = delta >= 0
            HStack(spacing: 2) {
                Image(systemName: up ? "arrow.up" : "arrow.down")
                Text(String(format: "%.1f%%", abs(pct)))
                Text("vs previous run")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(up ? Color.green : Color.red)
        }
    }
}
