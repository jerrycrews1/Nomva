import SwiftUI
import SwiftData
import Charts

struct WeightLoggingView: View {
    private enum ChartWindow: String, CaseIterable, Identifiable {
        case days7
        case days30
        case days90
        case year

        var id: String { rawValue }

        var shortLabel: String {
            switch self {
            case .days7:
                return "7D"
            case .days30:
                return "30D"
            case .days90:
                return "90D"
            case .year:
                return "1Y"
            }
        }

        var title: String {
            switch self {
            case .days7:
                return "Last 7 Days"
            case .days30:
                return "Last 30 Days"
            case .days90:
                return "Last 90 Days"
            case .year:
                return "Last Year"
            }
        }

        var daySpan: Int {
            switch self {
            case .days7:
                return 7
            case .days30:
                return 30
            case .days90:
                return 90
            case .year:
                return 365
            }
        }
    }

    private struct WeightChartPoint: Identifiable {
        let date: Date
        let weightLbs: Double

        var id: Date { date }
    }

    @Query(sort: \WeightEntry.date, order: .reverse) private var entries: [WeightEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager)  private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var routeCenter: NomvaRouteCenter
    @ObservedObject private var subManager = SubscriptionManager.shared

    @State private var showLogSheet = false
    @State private var showPaywall = false
    @State private var editingEntry: WeightEntry? = nil
    @State private var deleteEntry: WeightEntry? = nil
    @State private var showDeleteConfirm = false
    @State private var showUnitPicker = false
    @State private var selectedChartWindow: ChartWindow = .days30
    @State private var undoNotice: String?

    @AppStorage("weight_unit") private var unitRaw = WeightUnit.lbs.rawValue
    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lbs }
    private let contentInset: CGFloat = NomvaTheme.contentInset
    private let analytics = WeightAnalytics()

    init() {}

    private var rollingAverage: Double? {
        let recent = entries.prefix(7).map { $0.weightLbs }
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }

    private var chartDateRange: ClosedRange<Date>? {
        guard let latestEntryDate = entries.first?.date else { return nil }
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: latestEntryDate)
        guard let start = calendar.date(byAdding: .day, value: -(selectedChartWindow.daySpan - 1), to: end) else { return nil }
        return start ... end
    }

    private var chartData: [WeightChartPoint] {
        guard let range = chartDateRange else { return [] }

        let calendar = Calendar.current
        var weightsByDay: [Date: [Double]] = [:]

        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            guard range.contains(day) else { continue }
            weightsByDay[day, default: []].append(entry.weightLbs)
        }

        return weightsByDay.keys.sorted().map { day in
            let weights = weightsByDay[day] ?? []
            let average = weights.reduce(0, +) / Double(max(weights.count, 1))
            return WeightChartPoint(date: day, weightLbs: average)
        }
    }

    private var chartSummary: String {
        let loggedDayCount = chartData.count
        let loggedDayLabel = loggedDayCount == 1 ? "1 logged day" : "\(loggedDayCount) logged days"

        guard let first = chartData.first, let last = chartData.last, chartData.count > 1 else {
            return loggedDayLabel
        }

        let delta = displayedWeight(for: last.weightLbs - first.weightLbs)
        let verb = delta == 0 ? "flat" : delta < 0 ? "down" : "up"
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(0...1)))
        return "\(loggedDayLabel) • \(verb) \(magnitude) \(unit.shortLabel.lowercased())"
    }

    private var weightInsight: WeightInsight {
        analytics.analyze(entries: entries.map { (date: $0.date, weightLbs: $0.weightLbs) })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NomvaScreenBackground()

                List {
                    if let avg = rollingAverage {
                        Section {
                            averageCard(avg)
                                .listRowInsets(
                                    EdgeInsets(
                                        top: NomvaTheme.topCardGap,
                                        leading: contentInset,
                                        bottom: 8,
                                        trailing: contentInset
                                    )
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if !chartData.isEmpty {
                        Section {
                            weightChartCard
                                .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
                                .listRowInsets(
                                    EdgeInsets(
                                        top: NomvaTheme.sectionGap,
                                        leading: contentInset,
                                        bottom: NomvaTheme.sectionGap,
                                        trailing: contentInset
                                    )
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    Section {
                        Group {
                            if subManager.isPremium {
                                if weightInsight.signal == .insufficient {
                                    WeightInsightsInsufficientCard(
                                        entryCount: entries.count,
                                        minimumRequired: analytics.minimumEntries
                                    )
                                } else {
                                    WeightInsightsSection(insight: weightInsight, unit: unit)
                                }
                            } else {
                                WeightInsightsTeaser {
                                    showPaywall = true
                                }
                            }
                        }
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: contentInset,
                                bottom: NomvaTheme.sectionGap,
                                trailing: contentInset
                            )
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } header: {
                        sectionHeader("Insights")
                    }
                    .listSectionSeparator(.hidden)

                    if !entries.isEmpty {
                        Section {
                            ForEach(entries.prefix(50)) { entry in
                                WeightEntryRow(entry: entry, unit: unit)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingEntry = entry }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            deleteEntry = entry
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }

                                        Button {
                                            editingEntry = entry
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                    .listRowInsets(
                                        EdgeInsets(
                                            top: 2,
                                            leading: contentInset,
                                            bottom: 2,
                                            trailing: contentInset
                                        )
                                    )
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            sectionHeader("Log")
                        }
                    } else {
                        Section {
                            emptyStateCard
                                .listRowInsets(
                                    EdgeInsets(
                                        top: 0,
                                        leading: contentInset,
                                        bottom: NomvaTheme.sectionGap,
                                        trailing: contentInset
                                    )
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } header: {
                            sectionHeader("Log")
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    unitButton
                }
            }
            .sheet(isPresented: $showLogSheet) {
                WeightLogEntryView()
            }
            .sheet(item: $editingEntry) { entry in
                WeightLogEntryView(existingEntry: entry)
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack { PaywallView() }
            }
            .alert("Delete this entry?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let entry = deleteEntry {
                        modelContext.delete(entry)
                        try? modelContext.save()
                        presentUndo("Weight entry removed")
                    }
                    deleteEntry = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteEntry = nil
                }
            } message: {
                if let entry = deleteEntry {
                    Text("\(String(format: "%.1f", unit == .lbs ? entry.weightLbs : entry.weightLbs * 0.453592)) \(unit == .lbs ? "lbs" : "kg") on \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            .alert(
                "Weight Unit",
                isPresented: $showUnitPicker
            ) {
                Button(unit == .lbs ? "Pounds (lbs) ✓" : "Pounds (lbs)") {
                    unitRaw = WeightUnit.lbs.rawValue
                }
                Button(unit == .kg ? "Kilograms (kg) ✓" : "Kilograms (kg)") {
                    unitRaw = WeightUnit.kg.rawValue
                }
                Button("Cancel", role: .cancel) {}
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let undoNotice {
                        HStack {
                            Text(undoNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Undo") {
                                undoManager?.undo()
                                try? modelContext.save()
                                self.undoNotice = nil
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, contentInset)
                    }

                    NomvaBottomActionBar {
                        Button {
                            showLogSheet = true
                        } label: {
                            Label("Log Weight", systemImage: "plus")
                        }
                        .buttonStyle(NomvaPrimaryButtonStyle())
                    }
                }
            }
            .onAppear { modelContext.undoManager = undoManager }
            .onReceive(routeCenter.$currentRoute.compactMap { $0 }) { route in
                switch route {
                case .weight:
                    routeCenter.clear(route)
                case .weightLog:
                    showLogSheet = true
                    routeCenter.clear(route)
                default:
                    break
                }
            }
        }
    }

    private func presentUndo(_ message: String) {
        undoNotice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if undoNotice == message {
                undoNotice = nil
            }
        }
    }

    private func averageCard(_ avg: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("7-Day Average")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formatted(avg))
                .font(.system(size: 36, weight: .bold, design: .rounded))

            Text("Daily weight fluctuates 1–3 lbs from water, food, and timing. The 7-day average shows your true trend.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    @ViewBuilder
    private var weightChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedChartWindow.title)
                    .font(.headline)
                Text(chartSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            chartWindowPicker

            weightChart
        }
    }

    /// Trailing 7-day average at each logged day: the stable trend line the
    /// hero card tells users to trust.
    private var rollingAverageSeries: [(date: Date, value: Double)] {
        guard chartData.count >= 3 else { return [] }
        let calendar = Calendar.current
        return chartData.map { point in
            let windowStart = calendar.date(byAdding: .day, value: -6, to: point.date) ?? point.date
            let window = chartData.filter { $0.date >= windowStart && $0.date <= point.date }
            let average = window.reduce(0.0) { $0 + $1.weightLbs } / Double(max(window.count, 1))
            return (point.date, average)
        }
    }

    /// How far past today each window projects the trend. The 7-day view is
    /// too short for a meaningful extrapolation.
    private var projectionHorizonDays: Int? {
        switch selectedChartWindow {
        case .days7: return nil
        case .days30: return 14
        case .days90: return 30
        case .year: return 30
        }
    }

    /// Regression-based "on track for" projection, gated by WeightAnalytics
    /// (needs ≥5 logged days spanning ≥10 days and a sane slope).
    private var activeProjection: WeightAnalytics.Projection? {
        guard let horizon = projectionHorizonDays, chartData.count >= 2 else { return nil }
        return analytics.projection(
            entries: entries.map { (date: $0.date, weightLbs: $0.weightLbs) },
            daysAhead: horizon
        )
    }

    private var projectionAnchorLbs: Double? {
        guard let projection = activeProjection else { return nil }
        return projection.projectedWeightLbs - projection.slopeLbsPerDay * Double(projection.daysAhead)
    }

    private var chartYDomain: ClosedRange<Double>? {
        var values = chartData.map { displayedWeight(for: $0.weightLbs) }
        values += rollingAverageSeries.map { displayedWeight(for: $0.value) }
        if let projection = activeProjection {
            values.append(displayedWeight(for: projection.projectedWeightLbs))
        }
        guard let low = values.min(), let high = values.max() else { return nil }
        let padding = max(1.0, (high - low) * 0.25)
        return (low - padding) ... (high + padding)
    }

    private var chartXDomain: ClosedRange<Date> {
        let base = chartDateRange ?? Date() ... Date()
        if let projection = activeProjection, projection.targetDate > base.upperBound {
            return base.lowerBound ... projection.targetDate
        }
        return base
    }

    @ViewBuilder
    private var weightChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                // Soft gradient under the daily line
                if chartData.count > 1, let domain = chartYDomain {
                    ForEach(chartData) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            yStart: .value("Base", domain.lowerBound),
                            yEnd: .value("Weight", displayedWeight(for: point.weightLbs))
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [NomvaTheme.accent.opacity(0.22), NomvaTheme.accent.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }

                // 7-day average trend line
                if rollingAverageSeries.count >= 3 {
                    ForEach(rollingAverageSeries, id: \.date) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Average", displayedWeight(for: point.value)),
                            series: .value("Series", "7-day average")
                        )
                        .foregroundStyle(Color.secondary.opacity(0.55))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                    }
                }

                // Daily weights
                if chartData.count > 1 {
                    ForEach(chartData) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", displayedWeight(for: point.weightLbs)),
                            series: .value("Series", "Daily")
                        )
                        .foregroundStyle(NomvaTheme.accent)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                }

                // On-track projection from the last logged day
                if let projection = activeProjection,
                   let anchor = projectionAnchorLbs,
                   let lastDate = chartData.last?.date {
                    LineMark(
                        x: .value("Date", lastDate),
                        y: .value("Weight", displayedWeight(for: anchor)),
                        series: .value("Series", "Projection")
                    )
                    .foregroundStyle(NomvaTheme.accent.opacity(0.55))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))

                    LineMark(
                        x: .value("Date", projection.targetDate),
                        y: .value("Weight", displayedWeight(for: projection.projectedWeightLbs)),
                        series: .value("Series", "Projection")
                    )
                    .foregroundStyle(NomvaTheme.accent.opacity(0.55))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))

                    PointMark(
                        x: .value("Date", projection.targetDate),
                        y: .value("Weight", displayedWeight(for: projection.projectedWeightLbs))
                    )
                    .foregroundStyle(NomvaTheme.accent.opacity(0.55))
                    .symbolSize(40)
                    .annotation(position: .topLeading, spacing: 4) {
                        Text(formatted(projection.projectedWeightLbs))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                // Logged-day markers: white ring + accent core
                ForEach(chartData) { point in
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Weight", displayedWeight(for: point.weightLbs))
                    )
                    .foregroundStyle(Color(UIColor.systemBackground))
                    .symbolSize(56)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Weight", displayedWeight(for: point.weightLbs))
                    )
                    .foregroundStyle(NomvaTheme.accent)
                    .symbolSize(26)
                }

                // Latest weigh-in callout
                if let last = chartData.last {
                    PointMark(
                        x: .value("Date", last.date),
                        y: .value("Weight", displayedWeight(for: last.weightLbs))
                    )
                    .foregroundStyle(NomvaTheme.accent)
                    .symbolSize(26)
                    .annotation(position: .top, spacing: 6) {
                        Text(formatted(last.weightLbs))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(NomvaTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .chartXScale(domain: chartXDomain)
            .chartYScale(domain: chartYDomain ?? 100 ... 250)

            chartCaption
        }
        .chartXAxis {
            switch selectedChartWindow {
            case .days7:
                AxisMarks(preset: .aligned, values: .stride(by: .day, count: 2)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .days30:
                AxisMarks(preset: .aligned, values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .days90:
                AxisMarks(preset: .aligned, values: .stride(by: .month, count: 1)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .year:
                AxisMarks(preset: .aligned, values: .stride(by: .month, count: 2)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel {
                    if let weightValue = value.as(Double.self) {
                        Text(chartAxisLabel(for: weightValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: selectedChartWindow)
    }

    /// Legend + on-track summary under the chart.
    @ViewBuilder
    private var chartCaption: some View {
        HStack(spacing: 12) {
            if rollingAverageSeries.count >= 3 {
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 14, height: 2)
                    Text("7-day avg")
                }
            }
            if let projection = activeProjection {
                HStack(spacing: 5) {
                    Image(systemName: "scope")
                        .font(.caption2)
                        .foregroundStyle(NomvaTheme.accent)
                    Text("On track for \(formatted(projection.projectedWeightLbs)) by \(projection.targetDate.formatted(.dateTime.month(.abbreviated).day())) (\(weeklyRateLabel(projection.slopeLbsPerDay)))")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func weeklyRateLabel(_ slopeLbsPerDay: Double) -> String {
        let weekly = displayedWeight(for: abs(slopeLbsPerDay) * 7)
        let direction = slopeLbsPerDay <= 0 ? "−" : "+"
        let unitLabel = unit == .lbs ? "lbs" : "kg"
        return "\(direction)\(weekly.formatted(.number.precision(.fractionLength(1)))) \(unitLabel)/week"
    }

    private var chartWindowPicker: some View {
        HStack(spacing: 6) {
            ForEach(ChartWindow.allCases) { window in
                Button(window.shortLabel) {
                    selectedChartWindow = window
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selectedChartWindow == window ? .white : .secondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    Group {
                        if selectedChartWindow == window {
                            Capsule()
                                .fill(NomvaTheme.accentGradient)
                        } else {
                            Capsule()
                                .fill(Color(UIColor.secondarySystemBackground).opacity(0.64))
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(selectedChartWindow == window ? Color.clear : NomvaTheme.line, lineWidth: 1)
                )
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NomvaTheme.line, lineWidth: 1)
        )
    }

    private func displayedWeight(for weightLbs: Double) -> Double {
        unit == .lbs ? weightLbs : weightLbs * 0.453592
    }

    private func chartAxisLabel(for weight: Double) -> String {
        weight.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "scalemass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.4))

            Text("No weigh-ins yet")
                .foregroundStyle(.secondary)

            Text("Tap Log Weight to add your first entry.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
    }

    private func sectionHeader(_ title: String) -> some View {
        NomvaSectionHeaderText(title: title)
            .nomvaSectionHeaderPadding()
    }

    private var unitButton: some View {
        Button {
            showUnitPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(unit.shortLabel)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Weight unit \(unit.shortLabel)")
    }

    private func formatted(_ lbs: Double) -> String {
        unit == .lbs
            ? String(format: "%.1f lbs", lbs)
            : String(format: "%.1f kg", lbs * 0.453592)
    }
}

struct WeightEntryRow: View {
    let entry: WeightEntry
    let unit: WeightUnit

    private var loggedAt: String {
        entry.date.formatted(date: .omitted, time: .shortened)
    }

    private var displayWeight: String {
        unit == .lbs
            ? String(format: "%.1f lbs", entry.weightLbs)
            : String(format: "%.1f kg", entry.weightKg)
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary.opacity(0.8))

                    Text(loggedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(displayWeight)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NomvaTheme.line, lineWidth: 1)
        )
        .shadow(color: NomvaTheme.shadow.opacity(0.35), radius: 10, x: 0, y: 6)
    }
}

#Preview {
    WeightLoggingView()
        .environmentObject(NomvaRouteCenter.shared)
}

private extension WeightUnit {
    var shortLabel: String {
        rawValue.uppercased()
    }
}
