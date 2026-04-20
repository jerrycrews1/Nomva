import SwiftUI
import SwiftData
import Charts

struct WeightLoggingView: View {
    @Query(sort: \WeightEntry.date, order: .reverse) private var entries: [WeightEntry]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var subManager = SubscriptionManager.shared

    @State private var showLogSheet = false
    @State private var showPaywall = false
    @State private var editingEntry: WeightEntry? = nil
    @State private var deleteEntry: WeightEntry? = nil
    @State private var showDeleteConfirm = false
    @State private var showUnitPicker = false

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

    private var chartData: [WeightEntry] { Array(entries.prefix(30).reversed()) }

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
                            weightChart
                                .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
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
                            sectionHeader("Last 30 Days")
                        }
                    }

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
            .confirmationDialog(
                "Delete this entry?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let entry = deleteEntry { modelContext.delete(entry) }
                    deleteEntry = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteEntry = nil
                }
            }
            .confirmationDialog(
                "Weight Unit",
                isPresented: $showUnitPicker,
                titleVisibility: .visible
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
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    @ViewBuilder
    private var weightChart: some View {
        let smoothedPoints: [WeightDataPoint] = subManager.isPremium
            ? Array(weightInsight.dataPoints.suffix(30))
            : []
        let hasTrend = !smoothedPoints.isEmpty
        let rawOpacity: Double = hasTrend ? 0.3 : 1.0

        Chart {
            ForEach(chartData) { entry in
                LineMark(
                    x: .value("Date", entry.date),
                    y: .value("Weight", unit == .lbs ? entry.weightLbs : entry.weightKg)
                )
                .foregroundStyle(Color.orange.opacity(rawOpacity))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", entry.date),
                    y: .value("Weight", unit == .lbs ? entry.weightLbs : entry.weightKg)
                )
                .foregroundStyle(Color.orange.opacity(rawOpacity))
                .symbolSize(20)
            }

            ForEach(smoothedPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Smoothed", unit == .lbs ? point.smoothed : point.smoothed * 0.453592)
                )
                .foregroundStyle(Color.green)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .frame(height: 180)
        .chartYScale(domain: .automatic(includesZero: false))
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "scalemass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.4))

            Text("No weight entries yet")
                .foregroundStyle(.secondary)

            Text("Use Log Weight to add your first entry")
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
}

private extension WeightUnit {
    var shortLabel: String {
        rawValue.uppercased()
    }
}
