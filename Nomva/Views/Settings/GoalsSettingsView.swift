import SwiftUI
import SwiftData

struct GoalsSettingsView: View {
    @Query(sort: \DailyGoal.createdAt, order: .reverse) private var goals: [DailyGoal]
    @Environment(\.modelContext) private var modelContext
    @State private var showRecalculateSheet = false
    @State private var confirmationMessage: String?

    private var currentGoal: DailyGoal? { goals.first }

    var body: some View {
        Form {
            Section {
                GoalSliderRow(
                    label: "Calories",
                    value: binding(\.calories),
                    range: 1000...5000,
                    unit: "kcal",
                    step: 50
                )
            } footer: {
                Text("Your daily calorie target. Most adults need 1,600–2,500 depending on size and activity.")
            }

            Section {
                GoalSliderRow(
                    label: "Protein",
                    value: binding(\.protein),
                    range: 40...400,
                    unit: "g",
                    step: 5
                )
            } footer: {
                Text("Protein helps maintain muscle. A common target is 0.7–1g per pound of body weight.")
            }

            Section {
                GoalSliderRow(
                    label: "Carbs",
                    value: binding(\.carbs),
                    range: 50...600,
                    unit: "g",
                    step: 5
                )
            } footer: {
                Text("Your main energy source. Carbs fuel workouts and daily activity.")
            }

            Section {
                GoalSliderRow(
                    label: "Fat",
                    value: binding(\.fat),
                    range: 20...200,
                    unit: "g",
                    step: 5
                )
            } footer: {
                Text("Dietary fat supports hormones and vitamin absorption. Aim for 25–35% of your calories.")
            }

            Section {
                GoalSliderRow(
                    label: "Fiber",
                    value: binding(\.fiber),
                    range: 10...60,
                    unit: "g",
                    step: 1
                )
            }

            Section {
                Button("Recalculate from My Info or Activity Data") {
                    showRecalculateSheet = true
                }
            } footer: {
                Text("Recalculate uses your height, weight, and either a manual activity estimate, Apple Health activity, or Garmin Connect activity to suggest updated targets.")
            }
        }
        .navigationTitle("Goals")
        .safeAreaInset(edge: .top, spacing: 8) {
            if let confirmationMessage {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(confirmationMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6)
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showRecalculateSheet) {
            RecalculateGoalsView { source in
                if source == .appleHealth {
                    confirmationMessage = "Goals updated using Apple Health activity."
                } else if source == .garmin {
                    confirmationMessage = "Goals updated using Garmin activity."
                } else {
                    confirmationMessage = "Goals recalculated from your profile."
                }

                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.2)) {
                            confirmationMessage = nil
                        }
                    }
                }
            }
        }
        .task {
            ensureGoalExists()
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<DailyGoal, Double>) -> Binding<Double> {
        Binding(
            get: { currentGoal?[keyPath: keyPath] ?? defaultValue(for: keyPath) },
            set: { newValue in
                let goal = currentGoal ?? createDefaultGoal()
                goal[keyPath: keyPath] = newValue
            }
        )
    }

    private func ensureGoalExists() {
        guard currentGoal == nil else { return }
        _ = createDefaultGoal()
    }

    @discardableResult
    private func createDefaultGoal() -> DailyGoal {
        let goal = GoalService.defaultGoal()
        modelContext.insert(goal)
        return goal
    }

    private func defaultValue(for keyPath: ReferenceWritableKeyPath<DailyGoal, Double>) -> Double {
        let defaults = GoalService.defaultGoal()
        return defaults[keyPath: keyPath]
    }
}

// MARK: - Goal Slider Row

struct GoalSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.headline)
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $value, in: range, step: step)
                .tint(.orange)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recalculate Goals View

struct RecalculateGoalsView: View {
    private enum AppleHealthLoadState: Equatable {
        case checking
        case unavailable
        case needsAuthorization
        case loading
        case ready
        case noData
        case failed
    }

    @Query(sort: \DailyGoal.createdAt, order: .reverse) private var goals: [DailyGoal]
    @Query private var profiles: [UserProfile]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var garminManager: GarminManager
    @AppStorage("goal_activity_source") private var activitySourceRaw = GoalActivitySource.manual.rawValue
    @AppStorage("goal_activity_reference_active_calories") private var activityReferenceActiveCalories = 0.0
    @AppStorage("goal_manual_activity_level") private var storedManualActivityLevelRaw = ActivityLevel.moderatelyActive.rawValue

    @State private var biologicalSex: BiologicalSex = .notSpecified
    @State private var birthYear: Int = Calendar.current.component(.year, from: Date()) - 30
    @State private var heightFeet: Int = 5
    @State private var heightInches: Int = 9
    @State private var weightInput: String = "160"
    @State private var weightLbs: Double = 160
    @State private var activityLevel: ActivityLevel = .moderatelyActive
    @State private var activitySource: GoalActivitySource = .manual
    @State private var weightGoal: WeightGoal = .maintain
    @State private var appleHealthState: AppleHealthLoadState = .checking
    @State private var appleHealthSummary: AppleHealthActivitySummary?
    @State private var appleHealthErrorMessage: String?
    @State private var hasLoadedStoredValues = false
    @State private var isSaving = false

    let onApply: (GoalActivitySource) -> Void

    init(onApply: @escaping (GoalActivitySource) -> Void = { _ in }) {
        self.onApply = onApply
    }

    private var currentAge: Int {
        Calendar.current.component(.year, from: Date()) - birthYear
    }

    private var totalHeightInches: Int {
        heightFeet * 12 + heightInches
    }

    private var selectedActivityProfile: GoalActivityProfile {
        if activitySource == .appleHealth, let appleHealthSummary {
            return .measured(appleHealthSummary.averageActiveCalories, source: .appleHealth)
        }
        if activitySource == .garmin, let average = garminManager.averageActiveCalories {
            return .measured(average, source: .garmin)
        }
        return .manual(activityLevel)
    }

    private var projectedCalories: Double {
        GoalService.calculateSuggestedCalories(
            weightLbs: weightLbs,
            heightInches: totalHeightInches,
            age: max(currentAge, 18),
            sex: biologicalSex,
            activityProfile: selectedActivityProfile,
            goal: weightGoal
        ).rounded()
    }

    private var projectedMacros: (protein: Double, carbs: Double, fat: Double) {
        let macros = GoalService.suggestMacros(calories: projectedCalories, weightLbs: weightLbs, goal: weightGoal)
        return (macros.protein.rounded(), macros.carbs.rounded(), macros.fat.rounded())
    }

    private var applyDisabled: Bool {
        isSaving
            || weightLbs <= 0
            || (activitySource == .appleHealth && appleHealthSummary == nil)
            || (activitySource == .garmin && garminManager.averageActiveCalories == nil)
    }

    private var projectedSourceCaption: String {
        switch activitySource {
        case .manual:
            return "Using your \(activityLevel.displayName.lowercased()) activity estimate."
        case .appleHealth:
            if let appleHealthSummary {
                return "Using Apple Health average activity: \(Int(appleHealthSummary.averageActiveCalories.rounded())) active kcal/day."
            }
            return "Connect Apple Health to replace the manual estimate with real activity data."
        case .garmin:
            if let average = garminManager.averageActiveCalories {
                return "Using Garmin average activity: \(Int(average.rounded())) active kcal/day."
            }
            if garminManager.isConnected {
                return "Waiting for Garmin daily summaries to sync into Nomva Cloud."
            }
            return "Connect Garmin to replace the manual estimate with cloud-synced activity."
        }
    }

    private var appleHealthRowSubtitle: String {
        switch appleHealthState {
        case .checking, .loading:
            return "Checking recent activity data…"
        case .needsAuthorization:
            return "Connect to use recent active calories from Apple Health."
        case .ready:
            if let appleHealthSummary {
                return "\(Int(appleHealthSummary.averageActiveCalories.rounded())) active kcal/day average."
            }
            return GoalActivitySource.appleHealth.subtitle
        case .noData:
            return "No recent active calorie data was found yet."
        case .unavailable:
            return "Apple Health is not available on this device."
        case .failed:
            return appleHealthErrorMessage ?? "Nomva couldn't load Apple Health right now."
        }
    }

    private var appleHealthBadgeText: String? {
        switch appleHealthState {
        case .ready:
            return "Connected"
        case .needsAuthorization:
            return "Connect"
        case .noData:
            return "No Data"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Retry"
        case .checking, .loading:
            return nil
        }
    }

    private var garminRowSubtitle: String {
        if !garminManager.isConfigured {
            return "Finish Garmin credentials on Nomva Cloud to enable this source."
        }
        if let average = garminManager.averageActiveCalories {
            return "\(Int(average.rounded())) active kcal/day average from Garmin."
        }
        if garminManager.isConnected {
            return "Connected. Waiting for daily summaries from Garmin Connect."
        }
        if let lastError = garminManager.lastErrorMessage, !lastError.isEmpty {
            return lastError
        }
        return "Connect Garmin to use cloud-synced active calories."
    }

    private var garminBadgeText: String? {
        if garminManager.isLoading || garminManager.isConnecting {
            return nil
        }
        if !garminManager.isConfigured {
            return "Setup"
        }
        return garminManager.isConnected ? "Connected" : "Connect"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 16) {
                        Text("Projected Goals")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        HStack(spacing: 24) {
                            VStack(spacing: 4) {
                                Text("\(Int(projectedCalories))")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundStyle(.orange)
                                    .contentTransition(.numericText())
                                Text("kcal / day")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Divider()
                                .frame(height: 50)

                            HStack(spacing: 16) {
                                macroStat(label: "Pro", value: projectedMacros.protein, color: .blue)
                                macroStat(label: "Carb", value: projectedMacros.carbs, color: .green)
                                macroStat(label: "Fat", value: projectedMacros.fat, color: .yellow)
                            }
                        }

                        Text(projectedSourceCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6).opacity(0.6))

                    VStack(spacing: 28) {
                        profileSection(title: "Goal") {
                            HStack(spacing: 10) {
                                ForEach(WeightGoal.allCases, id: \.self) { goal in
                                    goalPill(goal)
                                }
                            }
                            .padding(12)
                        }

                        profileSection(title: "Activity Source") {
                            VStack(spacing: 8) {
                                activitySourceRow(.manual)
                                activitySourceRow(.appleHealth, subtitle: appleHealthRowSubtitle, badge: appleHealthBadgeText)
                                activitySourceRow(
                                    .garmin,
                                    subtitle: garminRowSubtitle,
                                    badge: garminBadgeText,
                                    isEnabled: garminManager.isConfigured || garminManager.isConnected
                                )

                                Text("Garmin Connect syncs through Nomva Cloud so the app can receive daily summaries and update calorie goals from real activity.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if activitySource == .manual {
                            profileSection(title: "Manual Activity Level") {
                                VStack(spacing: 8) {
                                    ForEach(ActivityLevel.allCases, id: \.self) { level in
                                        activityRow(level)
                                    }
                                }
                            }
                        }

                        if activitySource == .appleHealth {
                            profileSection(title: "Apple Health") {
                                appleHealthSection
                            }
                        }

                        if activitySource == .garmin {
                            profileSection(title: "Garmin Connect") {
                                garminSection
                            }
                        }

                        profileSection(title: "About You") {
                            VStack(spacing: 0) {
                                inlinePickerRow(label: "Sex") {
                                    Menu {
                                        ForEach(BiologicalSex.allCases, id: \.self) { option in
                                            Button(option.displayName) {
                                                biologicalSex = option
                                            }
                                        }
                                    } label: {
                                        menuValueLabel(biologicalSex.displayName)
                                    }
                                }

                                thinDivider()

                                inlinePickerRow(label: "Age") {
                                    Picker("Age", selection: $birthYear) {
                                        ForEach((1930...2010), id: \.self) {
                                            Text(String($0)).tag($0)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(.orange)
                                }

                                thinDivider()

                                inlinePickerRow(label: "Height") {
                                    HStack(spacing: 0) {
                                        Picker("", selection: $heightFeet) {
                                            ForEach(4...7, id: \.self) { Text("\($0)").tag($0) }
                                        }
                                        .pickerStyle(.menu)
                                        .tint(.orange)
                                        .fixedSize()

                                        Text("ft")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .padding(.trailing, 8)

                                        Picker("", selection: $heightInches) {
                                            ForEach(0...11, id: \.self) { Text("\($0)").tag($0) }
                                        }
                                        .pickerStyle(.menu)
                                        .tint(.orange)
                                        .fixedSize()

                                        Text("in")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                thinDivider()

                                HStack {
                                    Text("Weight")
                                        .font(.subheadline)
                                    Spacer()
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        TextField("160", text: $weightInput)
                                            .keyboardType(.decimalPad)
                                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.orange)
                                            .multilineTextAlignment(.trailing)
                                            .frame(width: 80)
                                            .onChange(of: weightInput) { oldValue, newValue in
                                                let filtered = newValue.filter { "0123456789.".contains($0) }
                                                let parts = filtered.components(separatedBy: ".")
                                                if parts.count > 2 {
                                                    weightInput = oldValue
                                                } else {
                                                    weightInput = filtered
                                                    if let val = Double(filtered) {
                                                        weightLbs = val
                                                    }
                                                }
                                            }
                                        Text("lbs")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Recalculate Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .fontWeight(.bold)
                        .foregroundStyle(applyDisabled ? Color.secondary : .orange)
                        .disabled(applyDisabled)
                }
            }
            .task {
                await loadStoredValuesIfNeeded()
                await garminManager.refreshIfNeeded()
            }
            .onChange(of: activitySource) { _, newValue in
                if newValue == .appleHealth {
                    Task { await refreshAppleHealthStatus(forceFetch: false) }
                } else if newValue == .garmin {
                    Task { await garminManager.refresh() }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: weightGoal)
            .animation(.easeInOut(duration: 0.2), value: activityLevel)
            .animation(.easeInOut(duration: 0.2), value: activitySource)
            .animation(.easeInOut(duration: 0.2), value: appleHealthState)
        }
    }

    // MARK: - Components

    private var appleHealthSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nomva uses your average active calories from the last 28 completed days. Apple Watch data usually gives the cleanest result.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            switch appleHealthState {
            case .checking, .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Apple Health activity…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            case .needsAuthorization:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect Apple Health to use recent active calories instead of a broad activity bucket.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Button("Connect Apple Health") {
                        Task { await connectAppleHealth() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            case .ready:
                if let appleHealthSummary {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            summaryTile(
                                title: "Avg Active",
                                value: "\(Int(appleHealthSummary.averageActiveCalories.rounded()))",
                                detail: "kcal / day"
                            )
                            summaryTile(
                                title: "Sample Days",
                                value: "\(appleHealthSummary.sampledDays)",
                                detail: "of \(appleHealthSummary.windowDays)"
                            )
                        }

                        Button("Refresh Apple Health Data") {
                            Task { await refreshAppleHealthStatus(forceFetch: true) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

            case .noData:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nomva couldn't find recent active calorie data. If you expected activity here, check Apple Health permissions and make sure workouts or movement are syncing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Check Again") {
                        Task { await refreshAppleHealthStatus(forceFetch: true) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            case .unavailable:
                Text("Apple Health isn't available on this device, so manual activity is the fallback here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

            case .failed:
                VStack(alignment: .leading, spacing: 12) {
                    Text(appleHealthErrorMessage ?? "Nomva hit an issue while reading Apple Health.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Try Again") {
                        Task { await refreshAppleHealthStatus(forceFetch: true) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private var garminSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Garmin activity syncs through Nomva Cloud. The app uses recent active calories from synced daily summaries to recalculate your baseline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            if garminManager.isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Garmin connection…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else if !garminManager.isConfigured {
                Text("Nomva Cloud still needs Garmin credentials and webhook settings before the app can connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else if !garminManager.isConnected {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect Garmin to use active calories from synced daily summaries instead of a broad activity bucket.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Button("Connect Garmin") {
                        Task { await garminManager.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    if garminManager.isConfigured, let lastError = garminManager.lastErrorMessage, !lastError.isEmpty {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        summaryTile(
                            title: "Avg Active",
                            value: "\(Int((garminManager.averageActiveCalories ?? 0).rounded()))",
                            detail: "kcal / day"
                        )
                        summaryTile(
                            title: "Sample Days",
                            value: "\(garminManager.status.sampledDays)",
                            detail: "recent sync"
                        )
                    }

                    if let latest = garminManager.status.latestSummary {
                        HStack(spacing: 12) {
                            summaryTile(
                                title: "Latest Day",
                                value: "\(Int(latest.activeCalories.rounded()))",
                                detail: "\(latest.date)"
                            )
                            summaryTile(
                                title: "Steps",
                                value: latest.steps.map { $0.formatted() } ?? "—",
                                detail: "latest sync"
                            )
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Refresh Garmin Data") {
                            Task { await garminManager.refresh() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)

                        Button("Disconnect") {
                            Task { await garminManager.disconnect() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }

                    if let lastWebhookAt = garminManager.status.lastWebhookAt {
                        Text("Last Garmin sync: \(formattedTimestamp(lastWebhookAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func macroStat(label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(Int(value))g")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
    }

    private func profileSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            content()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func goalPill(_ goal: WeightGoal) -> some View {
        let isSelected = weightGoal == goal
        return Button { weightGoal = goal } label: {
            VStack(spacing: 6) {
                Image(systemName: goalIcon(goal))
                    .font(.system(size: 18, weight: .medium))
                Text(goal.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Color.orange : Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func goalIcon(_ goal: WeightGoal) -> String {
        switch goal {
        case .loseWeight:
            return "flame.fill"
        case .maintain:
            return "equal.circle.fill"
        case .gainMuscle:
            return "dumbbell.fill"
        }
    }

    private func activitySourceRow(
        _ source: GoalActivitySource,
        subtitle: String? = nil,
        badge: String? = nil,
        isEnabled: Bool = true
    ) -> some View {
        let isSelected = activitySource == source
        return Button {
            guard isEnabled else { return }
            activitySource = source
        } label: {
            HStack(spacing: 12) {
                Image(systemName: source.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? .orange : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                    Text(subtitle ?? source.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? .orange : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(isSelected ? 0.14 : 0.08))
                        .clipShape(Capsule())
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? .orange : Color(.tertiaryLabel))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(isSelected ? Color.orange.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.72)
    }

    private func activityRow(_ level: ActivityLevel) -> some View {
        let isSelected = activityLevel == level
        return Button { activityLevel = level } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? .orange : Color(.tertiaryLabel))

                VStack(alignment: .leading, spacing: 2) {
                    Text(level.displayName)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                    Text(level.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(isSelected ? Color.orange.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
    }

    private func summaryTile(title: String, value: String, detail: String) -> some View {
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
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func menuValueLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func inlinePickerRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            content()
        }
        .frame(minHeight: 32)
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
    }

    private func thinDivider() -> some View {
        Divider()
            .padding(.leading, 16)
    }

    private func loadStoredValuesIfNeeded() async {
        guard !hasLoadedStoredValues else { return }
        hasLoadedStoredValues = true

        activitySource = GoalActivitySource(rawValue: activitySourceRaw) ?? .manual

        if let profile = profiles.first {
            biologicalSex = BiologicalSex(rawValue: profile.biologicalSex) ?? .notSpecified
            birthYear = profile.birthYear

            let safeHeight = max(profile.heightInches, 48)
            heightFeet = max(4, min(7, safeHeight / 12))
            heightInches = min(11, max(0, safeHeight % 12))

            activityLevel = ActivityLevel(rawValue: profile.activityLevel) ?? .moderatelyActive
            weightGoal = WeightGoal(rawValue: profile.weightGoal) ?? .maintain
        } else {
            activityLevel = ActivityLevel(rawValue: storedManualActivityLevelRaw) ?? .moderatelyActive
        }

        if let latestWeight = weightEntries.first {
            weightLbs = latestWeight.weightLbs
            weightInput = formattedWeight(latestWeight.weightLbs)
        }

        await refreshAppleHealthStatus(forceFetch: activitySource == .appleHealth)
        if activitySource == .garmin {
            await garminManager.refresh()
        }
    }

    private func connectAppleHealth() async {
        appleHealthState = .loading
        appleHealthErrorMessage = nil

        do {
            try await AppleHealthService.requestAuthorization()
            await refreshAppleHealthStatus(forceFetch: true)
        } catch {
            appleHealthState = .failed
            appleHealthErrorMessage = error.localizedDescription
        }
    }

    private func refreshAppleHealthStatus(forceFetch: Bool) async {
        guard AppleHealthService.isAvailable() else {
            appleHealthState = .unavailable
            appleHealthSummary = nil
            return
        }

        if forceFetch || appleHealthState == .checking {
            appleHealthState = .loading
        }

        do {
            switch try await AppleHealthService.requestStatus() {
            case .unavailable:
                appleHealthState = .unavailable
                appleHealthSummary = nil
            case .shouldRequest:
                appleHealthState = .needsAuthorization
                appleHealthSummary = nil
            case .ready:
                let summary = try await AppleHealthService.fetchAverageActiveCalories()
                appleHealthSummary = summary
                appleHealthState = summary == nil ? .noData : .ready
            case .unknown:
                appleHealthState = .failed
                appleHealthErrorMessage = "Nomva couldn't determine Apple Health access."
            }
        } catch {
            appleHealthState = .failed
            appleHealthErrorMessage = error.localizedDescription
        }
    }

    private func formattedWeight(_ weight: Double) -> String {
        if weight.rounded() == weight {
            return String(Int(weight))
        }
        return weight.formatted(.number.precision(.fractionLength(1)))
    }

    private func formattedTimestamp(_ isoString: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: isoString) else { return isoString }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func apply() {
        guard !applyDisabled else { return }
        isSaving = true

        let cal = projectedCalories
        let macros = projectedMacros

        if let goal = goals.first {
            goal.calories = cal
            goal.protein = macros.protein
            goal.carbs = macros.carbs
            goal.fat = macros.fat
        } else {
            let goal = DailyGoal(
                calories: cal,
                protein: macros.protein,
                carbs: macros.carbs,
                fat: macros.fat
            )
            modelContext.insert(goal)
        }

        if let profile = profiles.first {
            profile.biologicalSex = biologicalSex.rawValue
            profile.birthYear = birthYear
            profile.heightInches = totalHeightInches
            profile.activityLevel = activityLevel.rawValue
            profile.weightGoal = weightGoal.rawValue
        } else {
            let profile = UserProfile(
                biologicalSex: biologicalSex.rawValue,
                birthYear: birthYear,
                heightInches: totalHeightInches,
                activityLevel: activityLevel.rawValue,
                weightGoal: weightGoal.rawValue
            )
            profile.onboardingComplete = true
            modelContext.insert(profile)
        }

        activitySourceRaw = activitySource.rawValue
        storedManualActivityLevelRaw = activityLevel.rawValue
        switch activitySource {
        case .manual:
            activityReferenceActiveCalories = 0
        case .appleHealth:
            activityReferenceActiveCalories = appleHealthSummary?.averageActiveCalories ?? 0
        case .garmin:
            activityReferenceActiveCalories = garminManager.averageActiveCalories ?? 0
        }
        UserDefaults.standard.set(true, forKey: "goals_personalized")
        onApply(activitySource)
        dismiss()
    }
}
