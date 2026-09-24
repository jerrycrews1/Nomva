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

    private struct WeightChartSnapshot {
        let points: [WeightChartPoint]
        let averages: [(date: Date, value: Double)]
        let xDomain: ClosedRange<Date>
        let yDomain: ClosedRange<Double>?
        let summary: String
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
    @State private var showWeightSync = false
    @State private var selectedChartWindow: ChartWindow = .days30
    @State private var undoNotice: String?
    @State private var saveFailure: String?

    @AppStorage("weight_unit") private var unitRaw = WeightUnit.lbs.rawValue
    @AppStorage(WeightSyncPreferences.appleHealthImportKey) private var appleHealthImportEnabled = false
    @AppStorage(WeightSyncPreferences.appleHealthExportKey) private var appleHealthExportEnabled = false
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

    private func chartSummary(for points: [WeightChartPoint]) -> String {
        let loggedDayCount = points.count
        let loggedDayLabel = loggedDayCount == 1 ? "1 logged day" : "\(loggedDayCount) logged days"

        guard let first = points.first, let last = points.last, points.count > 1 else {
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
        let chart = makeChartSnapshot()
        let insight = subManager.isPremium ? weightInsight : nil
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

                    if !chart.points.isEmpty {
                        Section {
                            weightChartCard(chart)
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
                            if let insight {
                                if insight.signal == .insufficient {
                                    WeightInsightsInsufficientCard(
                                        entryCount: entries.count,
                                        minimumRequired: analytics.minimumEntries
                                    )
                                } else {
                                    WeightInsightsSection(insight: insight, unit: unit)
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

                    Section {
                        Button {
                            showWeightSync = true
                        } label: {
                            weightSyncCard
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("weight.sync")
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
                        sectionHeader("History")
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
                                        .tint(NomvaTheme.accent)
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showWeightSync = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Weight history sync")

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
            .sheet(isPresented: $showWeightSync) {
                NavigationStack { WeightSyncSettingsView() }
            }
            .alert("Couldn't save", isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
                Button("OK") { saveFailure = nil }
            } message: { Text(saveFailure ?? "") }
            .alert("Delete this entry?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let entry = deleteEntry {
                        undoManager?.beginUndoGrouping()
                        WeightSyncCoordinator.queueDeletion(entry, in: modelContext)
                        do {
                            try modelContext.save()
                            undoManager?.endUndoGrouping()
                            presentUndo("Weight entry removed")
                        } catch {
                            modelContext.rollback()
                            undoManager?.endUndoGrouping()
                            saveFailure = "The deletion could not be saved. Your weigh-in is still there."
                        }
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
                                NomvaPersistence.save(modelContext)
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
            .task {
                await refreshEnabledWeightSources()
            }
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

    @MainActor
    private func refreshEnabledWeightSources() async {
        if appleHealthImportEnabled {
            do {
                _ = try await WeightSyncCoordinator.importAppleHealth(into: modelContext)
            } catch {
                WeightSyncPreferences.record(error: error)
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

            Text("Daily weight can vary with water, food, and timing. The 7-day average smooths recent readings; it is still an estimate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    @ViewBuilder
    private func weightChartCard(_ chart: WeightChartSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedChartWindow.title)
                    .font(.headline)
                Text(chart.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            chartWindowPicker

            weightChart(chart)
        }
    }

    /// Trailing 7-day average at each logged day: the stable trend line the
    /// hero card tells users to trust.
    private func rollingAverageSeries(for points: [WeightChartPoint]) -> [(date: Date, value: Double)] {
        guard points.count >= 3 else { return [] }
        let calendar = Calendar.current
        var series: [(date: Date, value: Double)] = []
        series.reserveCapacity(points.count)
        var firstInWindow = 0
        var windowTotal = 0.0

        for point in points {
            windowTotal += point.weightLbs
            let windowStart = calendar.date(byAdding: .day, value: -6, to: point.date) ?? point.date
            while points[firstInWindow].date < windowStart {
                windowTotal -= points[firstInWindow].weightLbs
                firstInWindow += 1
            }
            series.append((point.date, windowTotal / Double(series.count + 1 - firstInWindow)))
        }
        return series
    }

    /// Build the data used by every chart mark once for this view update.
    private func makeChartSnapshot() -> WeightChartSnapshot {
        let points = chartData
        let averages = rollingAverageSeries(for: points)

        var values = points.map { displayedWeight(for: $0.weightLbs) }
        values += averages.map { displayedWeight(for: $0.value) }
        let yDomain: ClosedRange<Double>?
        if let low = values.min(), let high = values.max() {
            let padding = max(1.0, (high - low) * 0.25)
            yDomain = (low - padding) ... (high + padding)
        } else {
            yDomain = nil
        }

        let base = chartDateRange ?? Date() ... Date()
        return WeightChartSnapshot(
            points: points,
            averages: averages,
            xDomain: base,
            yDomain: yDomain,
            summary: chartSummary(for: points)
        )
    }

    @ViewBuilder
    private func weightChart(_ chart: WeightChartSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                // Soft gradient under the daily line
                if chart.points.count > 1, let domain = chart.yDomain {
                    ForEach(chart.points) { point in
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
                if chart.averages.count >= 3 {
                    ForEach(chart.averages, id: \.date) { point in
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
                if chart.points.count > 1 {
                    ForEach(chart.points) { point in
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

                // Logged-day markers: white ring + accent core
                ForEach(chart.points) { point in
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
                if let last = chart.points.last {
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
            .chartXScale(domain: chart.xDomain)
            .chartYScale(domain: chart.yDomain ?? 100 ... 250)

            chartCaption(chart)
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

    /// Legend under the chart.
    @ViewBuilder
    private func chartCaption(_ chart: WeightChartSnapshot) -> some View {
        HStack(spacing: 12) {
            if chart.averages.count >= 3 {
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 14, height: 2)
                    Text("7-day avg")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var chartWindowPicker: some View {
        HStack(spacing: 6) {
            ForEach(ChartWindow.allCases) { window in
                Button(window.shortLabel) {
                    selectedChartWindow = window
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selectedChartWindow == window ? NomvaTheme.onAccent : Color.secondary)
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

    private var weightSyncCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(NomvaTheme.accent)
                .frame(width: 42, height: 42)
                .background(NomvaTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("Weight History Sync")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(weightSyncSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
    }

    private var weightSyncSummary: String {
        var sources: [String] = []
        if appleHealthImportEnabled || appleHealthExportEnabled {
            sources.append("Apple Health")
        }
        return sources.isEmpty ? "Import existing weigh-ins or save new ones to Apple Health." : "On for \(sources.joined(separator: " and "))."
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
            .foregroundStyle(NomvaTheme.accent)
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

                Label(entry.resolvedSourceName, systemImage: entry.dataSource.systemImage)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
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

struct WeightSyncSettingsView: View {
    @Query(sort: \WeightEntry.date, order: .reverse) private var entries: [WeightEntry]
    @Query private var syncStates: [WeightSyncState]
    @Query private var tombstones: [WeightSyncTombstone]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage(WeightSyncPreferences.appleHealthImportKey) private var appleHealthImportEnabled = false
    @AppStorage(WeightSyncPreferences.appleHealthExportKey) private var appleHealthExportEnabled = false
    @AppStorage(WeightSyncPreferences.lastErrorKey) private var persistedErrorMessage = ""

    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var importedAppleCount: Int {
        entries.filter { $0.dataSource == .appleHealth }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Weight History")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Bring existing weigh-ins into Nomva and choose where new Nomva weigh-ins are saved.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SettingsSectionCard("Garmin → Apple Health → Nomva", detail: "Recommended for your Garmin scale.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("In Garmin Connect, enable sharing Weight with Apple Health. Open Garmin Connect in the foreground after weighing so it can send the measurement.")
                        Text("Then allow Nomva to read Weight in Apple Health and turn on Import Weight History below. Nomva weigh-ins can be saved back to Apple Health; Apple Health does not send them to Garmin.")
                        Text("Garmin may share only recent history when first connected. Older measurements appear here only if they are available in Apple Health.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }

                SettingsSectionCard("Apple Health", detail: "Runs privately on this device.") {
                    VStack(spacing: 14) {
                        syncToggle(
                            title: "Import Weight History",
                            subtitle: importedAppleCount == 0
                                ? "Show Apple Health weigh-ins in Nomva"
                                : "\(importedAppleCount) Apple Health weigh-ins in Nomva",
                            systemImage: "arrow.down.circle.fill",
                            isOn: $appleHealthImportEnabled
                        )
                        .onChange(of: appleHealthImportEnabled) { _, enabled in
                            guard enabled else { return }
                            Task { await enableAppleHealthImport() }
                        }

                        Divider()

                        syncToggle(
                            title: "Save Nomva Weigh-ins",
                            subtitle: "Write new and edited Nomva weights to Apple Health",
                            systemImage: "arrow.up.circle.fill",
                            isOn: $appleHealthExportEnabled
                        )
                        .onChange(of: appleHealthExportEnabled) { _, enabled in
                            guard enabled else { return }
                            Task { await enableAppleHealthExport() }
                        }
                    }
                }

                SettingsSectionCard("Across your Apple devices", detail: "Apple Health handles your weight history.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Use the same Apple Account and enable Health in iCloud settings on each device. In Nomva, allow Weight access and turn on Import Weight History on each device.")
                        Text("Nomva does not send these weigh-ins to its server. Food logs, chat history, and goals stay on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }

                SettingsSectionCard("Sync status", detail: "Read checks and pending changes on this device.") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let state = syncStates.first, let readAt = state.lastReadAt {
                            Text("Last Health check: \(readAt.formatted(date: .abbreviated, time: .shortened))")
                            if let sampleAt = state.lastSampleAt {
                                Text("Latest received: \(sampleAt.formatted(date: .abbreviated, time: .shortened)) · \(state.lastSourceName ?? "Apple Health")")
                            }
                        } else { Text("Apple Health has not been checked yet.") }
                        let pending = entries.filter { $0.dataSource == .nomva && $0.healthExportedFingerprint != $0.healthFingerprint }.count + tombstones.filter(\.pending).count
                        Text(appleHealthExportEnabled ? "\(pending) changes waiting to save to Apple Health" : "Saving to Apple Health is off")
                        Text("An empty Health result cannot confirm read permission. Manage Weight access in the Health app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }

                Button {
                    Task { await syncNow() }
                } label: {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView()
                                .tint(NomvaTheme.onAccent)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(isWorking ? "Syncing Weight History…" : "Sync Now")
                    }
                }
                .buttonStyle(NomvaPrimaryButtonStyle())
                .disabled(isWorking || !hasEnabledSource)

                if appleHealthImportEnabled {
                    Button("Recheck All Health History") {
                        Task { await syncNow(recheckHistory: true) }
                    }
                    .disabled(isWorking)
                    Text("Use this after changing Health permissions or when an older weigh-in is missing. Existing entries and removed-weight preferences are preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NomvaTheme.success)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NomvaTheme.danger)
                } else if !persistedErrorMessage.isEmpty {
                    Label(persistedErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NomvaTheme.danger)
                }
            }
            .padding(.horizontal, NomvaTheme.contentInset)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(NomvaScreenBackground())
        .navigationTitle("Weight Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var hasEnabledSource: Bool {
        appleHealthImportEnabled || appleHealthExportEnabled
    }

    private func syncToggle(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(NomvaTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(NomvaTheme.accent)
        .disabled(isWorking)
    }

    @MainActor
    private func enableAppleHealthImport() async {
        await performSync {
            try await AppleHealthService.requestWeightReadAuthorization()
            let result = try await WeightSyncCoordinator.importAppleHealth(into: modelContext)
            return result.imported == 0
                ? "No new readable weigh-ins were returned. If you expected one, check Weight read access in Apple Health and open Garmin Connect first."
                : "Imported \(result.imported) weigh-in\(result.imported == 1 ? "" : "s") from Apple Health."
        } onFailure: {
            appleHealthImportEnabled = false
        }
    }

    @MainActor
    private func enableAppleHealthExport() async {
        await performSync {
            try await AppleHealthService.requestWeightWriteAuthorization()
            guard AppleHealthService.weightWriteAuthorizationStatus() == .sharingAuthorized else {
                throw AppleHealthServiceError.weightPermissionDenied
            }
            let count = try await WeightSyncCoordinator.exportAllNomvaWeightsToAppleHealth(
                from: entries,
                in: modelContext
            )
            return count == 0
                ? "New Nomva weigh-ins will be saved to Apple Health."
                : "Saved \(count) existing Nomva weigh-in\(count == 1 ? "" : "s") to Apple Health."
        } onFailure: {
            appleHealthExportEnabled = false
        }
    }

    @MainActor
    private func syncNow(recheckHistory: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        defer { isWorking = false }
        let report = await WeightSyncCoordinator.synchronize(in: modelContext,
            importEnabled: appleHealthImportEnabled, exportEnabled: appleHealthExportEnabled,
            recheckHistory: recheckHistory)
        statusMessage = report.summary
        persistedErrorMessage = report.errors.joined(separator: "\n")
        errorMessage = report.errors.isEmpty ? nil : persistedErrorMessage
    }

    @MainActor
    private func performSync(
        operation: () async throws -> String,
        onFailure: () -> Void = {}
    ) async {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        defer { isWorking = false }

        do {
            statusMessage = try await operation()
            persistedErrorMessage = ""
        } catch {
            onFailure()
            errorMessage = error.localizedDescription
            persistedErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    WeightLoggingView()
        .environmentObject(NomvaRouteCenter.shared)
        .environmentObject(GarminManager.shared)
}

private extension WeightUnit {
    var shortLabel: String {
        rawValue.uppercased()
    }
}
