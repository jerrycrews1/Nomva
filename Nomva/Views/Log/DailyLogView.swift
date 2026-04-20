import SwiftUI
import SwiftData

struct DailyLogView: View {
    @Query(sort: \FoodEntry.date) private var allEntries: [FoodEntry]
    @Query                        private var goals: [DailyGoal]
    @Environment(\.modelContext)  private var modelContext
    @EnvironmentObject private var garminManager: GarminManager
    @AppStorage("goal_activity_source") private var activitySourceRaw = GoalActivitySource.manual.rawValue
    @AppStorage("goal_activity_reference_active_calories") private var activityReferenceActiveCalories = 0.0

    @State private var selectedDate      = Date.now
    @State private var selectedEntry:    FoodEntry? = nil
    @State private var showCustomFoodCreate = false
    @State private var showManualSearch     = false
    @State private var selectedMealForSearch: String? = nil

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(selectedDate) }
    private var dayStart: Date { cal.startOfDay(for: selectedDate) }
    private var dayEnd:   Date { cal.date(byAdding: .day, value: 1, to: dayStart)! }

    private var selectedDayEntries: [FoodEntry] {
        allEntries.filter { $0.date >= dayStart && $0.date < dayEnd }
    }

    private var currentGoal: DailyGoal { goals.first ?? GoalService.defaultGoal() }
    private var selectedActivitySource: GoalActivitySource {
        GoalActivitySource(rawValue: activitySourceRaw) ?? .manual
    }
    private var garminSummaryForSelectedDate: GarminDailyActivitySummary? {
        garminManager.summary(for: selectedDate)
    }
    private var displayGoal: DailyGoal {
        let base = currentGoal
        let calories: Double

        if selectedActivitySource == .garmin || selectedActivitySource == .appleHealth {
            // Use the rolling average of recent active calories — NOT today's
            // partial real-time value. This keeps the goal stable all day so the
            // user can plan meals in the morning without undereating.
            // For past dates that have a completed summary, use that day's actual value.
            let activityCalories: Double
            if !isToday, let summary = garminSummaryForSelectedDate {
                // Past date with a full day of data — use the actual value
                activityCalories = summary.activeCalories
            } else if let avg = garminManager.averageActiveCalories, avg > 0 {
                // Today or any date without data — use rolling average
                activityCalories = avg
            } else {
                activityCalories = activityReferenceActiveCalories
            }

            calories = GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: base.calories,
                dailyActiveCalories: activityCalories,
                referenceActiveCalories: activityReferenceActiveCalories
            )
        } else {
            calories = base.calories
        }

        return DailyGoal(
            calories: calories,
            protein: base.protein,
            carbs: base.carbs,
            fat: base.fat,
            fiber: base.fiber
        )
    }
    private var dayTotals: NutritionTotals { NutritionTotals.from(entries: selectedDayEntries) }

    private var groupedEntries: [(String, [FoodEntry])] {
        let order = ["breakfast", "lunch", "dinner", "snack"]
        let grouped = Dictionary(grouping: selectedDayEntries, by: { $0.meal })
        return order.compactMap { meal in
            guard let entries = grouped[meal], !entries.isEmpty else { return nil }
            return (meal, entries)
        }
    }

    private let contentInset: CGFloat = NomvaTheme.contentInset

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                NomvaScreenBackground()

                List {
                    Section {
                        MacroRingsView(consumed: dayTotals, goal: displayGoal)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: NomvaTheme.topCardGap, leading: contentInset, bottom: 8, trailing: contentInset))
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)

                    ForEach(groupedEntries, id: \.0) { meal, mealEntries in
                        Section {
                            ForEach(mealEntries) { entry in
                                FoodEntryRow(entry: entry)
                                    .listRowInsets(EdgeInsets(top: 2, leading: contentInset, bottom: 2, trailing: contentInset))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedEntry = entry }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            modelContext.delete(entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        Button {
                                            selectedEntry = entry
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                            }
                        } header: {
                            HStack {
                                NomvaSectionHeaderText(title: meal.capitalized)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int(mealEntries.reduce(0.0) { $0 + $1.calories })) cal")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                                
                                Button {
                                    selectedMealForSearch = meal
                                    showManualSearch = true
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.title3)
                                }
                                .padding(.leading, 8)
                            }
                            .nomvaSectionHeaderPadding()
                        }
                    }

                    if groupedEntries.isEmpty {
                        Section {
                            emptyLogView
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                                .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if isToday {
                        Section {
                            WaterTrackerSection()
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: hydrationTopInset, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                                .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if garminManager.isConnected {
                        Section {
                            garminActivityCard
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                                .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    Section {
                        UnpersonalizedGoalsBanner()
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await garminManager.refresh(forceSync: true)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { dateNavigator }
                if isToday {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showCustomFoodCreate = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("Create custom food")
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                FoodEntryEditView(entry: entry)
            }
            .sheet(isPresented: $showCustomFoodCreate) {
                NavigationStack { CustomFoodCreateView() }
            }
            .sheet(isPresented: $showManualSearch) {
                ManualFoodSearchView(isPresented: $showManualSearch)
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                if isToday { selectedDate = .now }
            }
            .task {
                await garminManager.refreshIfNeeded()
            }
            .safeAreaInset(edge: .bottom) {
                if isToday {
                    addFoodBar
                }
            }
        }
    }

    private var dateNavigator: some View {
        NomvaDateNavigator(
            label: dateLabel,
            isCurrent: isToday,
            canAdvance: !isToday,
            onPrevious: {
                selectedDate = cal.date(byAdding: .day, value: -1, to: selectedDate)!
            },
            onJumpToCurrent: {
                selectedDate = .now
            },
            onNext: {
                guard !isToday else { return }
                let next = cal.date(byAdding: .day, value: 1, to: selectedDate)!
                if next <= .now { selectedDate = next }
            }
        )
    }

    private var addFoodBar: some View {
        NomvaBottomActionBar {
            Button {
                selectedMealForSearch = nil
                showManualSearch = true
            } label: {
                Label("Add Food", systemImage: "plus")
            }
            .buttonStyle(NomvaPrimaryButtonStyle())
        }
    }

    private var navTitle: String { isToday ? "Today's Log" : "Log" }
    private var hydrationTopInset: CGFloat { groupedEntries.isEmpty ? 0 : NomvaTheme.sectionGap }

    private var dateLabel: String {
        if isToday { return "Today" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday" }
        let df = DateFormatter()
        df.dateFormat = cal.component(.year, from: selectedDate) == cal.component(.year, from: .now)
            ? "MMM d" : "MMM d, yyyy"
        return df.string(from: selectedDate)
    }

    private var emptyLogView: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 34))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Nothing logged yet")
                .font(.headline)
            if isToday {
                Text("Start with Add food, then review meals here as the day fills in.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
    }

    private var garminActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Garmin Activity")
                        .font(.headline)
                    Text(garminDateCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if garminManager.isSyncing {
                    ProgressView()
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "figure.walk.motion")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if garminManager.isSyncing && garminSummaryForSelectedDate == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing with Garmin…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if let summary = garminSummaryForSelectedDate {
                HStack(spacing: 12) {
                    GarminLogStat(
                        title: "Active Calories",
                        value: "\(Int(summary.activeCalories.rounded()))",
                        detail: isToday ? "so far" : "kcal"
                    )
                    GarminLogStat(
                        title: "Steps",
                        value: summary.steps.map { $0.formatted() } ?? "—",
                        detail: "steps"
                    )
                }

                if selectedActivitySource == .garmin {
                    Text(goalAdjustmentCaption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Garmin is connected, but your calorie goal is still using \(selectedActivitySource.displayName.lowercased()). Switch the goal source in Settings > Goals to make this day adjust automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if isToday {
                // Today but no Garmin data yet — still show goal info from average
                if selectedActivitySource == .garmin, let avg = garminManager.averageActiveCalories, avg > 0 {
                    Text(goalAdjustmentCaption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("No Garmin activity synced for today yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await garminManager.manualSync() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.trianglehead.2.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("No Garmin data for this date.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .nomvaCard(.standard, padding: NomvaTheme.standardCardPadding)
    }

    private var garminDateCaption: String {
        if isToday {
            return "Today's synced activity"
        }
        return "Synced activity for \(dateLabel)"
    }

    /// Explains how the calorie goal was adjusted — uses rolling average for
    /// today (stable all day) and the actual value for completed past dates.
    private var goalAdjustmentCaption: String {
        let base = currentGoal.calories

        if !isToday, let summary = garminSummaryForSelectedDate {
            // Past date with completed data — show actual delta
            let delta = GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: base,
                dailyActiveCalories: summary.activeCalories,
                referenceActiveCalories: activityReferenceActiveCalories
            ) - base
            let rounded = Int(delta.rounded())
            if rounded == 0 {
                return "Your calorie goal matched your Garmin activity baseline for this day."
            } else if rounded > 0 {
                return "Garmin activity added \(rounded) kcal to your base goal for this day."
            } else {
                return "Garmin activity trimmed \(abs(rounded)) kcal from your base goal for this day."
            }
        }

        // Today or no summary — goal is based on the rolling average
        if let avg = garminManager.averageActiveCalories, avg > 0 {
            let delta = GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: base,
                dailyActiveCalories: avg,
                referenceActiveCalories: activityReferenceActiveCalories
            ) - base
            let rounded = Int(delta.rounded())
            let avgRounded = Int(avg.rounded())
            if rounded == 0 {
                return "Your calorie goal uses your recent Garmin average (\(avgRounded) active kcal/day) — right on your baseline."
            } else if rounded > 0 {
                return "Your calorie goal is based on your recent Garmin average (\(avgRounded) active kcal/day), adding \(rounded) kcal to your base goal."
            } else {
                return "Your calorie goal is based on your recent Garmin average (\(avgRounded) active kcal/day), trimming \(abs(rounded)) kcal from your base goal."
            }
        }

        return "Your calorie goal adjusts based on Garmin activity data."
    }

}

struct FoodEntryRow: View {
    let entry: FoodEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline).bold().lineLimit(1)
                    .foregroundColor(.primary)
                if let brand = entry.brand { 
                    Text(brand).font(.caption).foregroundColor(.secondary) 
                }
                Text(entry.portionDescription).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(entry.calories)) cal").font(.subheadline).bold()
                    .foregroundColor(.primary)
                Text("\(Int(entry.proteinG))g P · \(Int(entry.carbsG))g C · \(Int(entry.fatG))g F").font(.caption2).foregroundColor(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GarminLogStat: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    DailyLogView()
        .environmentObject(GarminManager.shared)
}
