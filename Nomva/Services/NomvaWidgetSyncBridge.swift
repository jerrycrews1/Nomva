import SwiftData
import SwiftUI

struct NomvaWidgetSyncBridge: View {
    @Query(sort: \FoodEntry.date) private var allFoodEntries: [FoodEntry]
    @Query(sort: \WaterEntry.date) private var allWaterEntries: [WaterEntry]
    @Query(sort: \WeightEntry.date, order: .reverse) private var allWeightEntries: [WeightEntry]
    @Query(sort: \DailyGoal.createdAt, order: .reverse) private var goals: [DailyGoal]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var garminManager: GarminManager

    @AppStorage("goal_activity_source") private var activitySourceRaw = GoalActivitySource.manual.rawValue
    @AppStorage("goal_activity_reference_active_calories") private var activityReferenceActiveCalories = 0.0
    @AppStorage("water_goal_oz") private var waterGoalOz = 64.0
    @AppStorage("weight_unit") private var weightUnitRaw = WeightUnit.lbs.rawValue

    private let analytics = WeightAnalytics()

    private var syncSignature: String {
        [
            foodSignature,
            waterSignature,
            goalSignature,
            weightSignature,
            garminSignature
        ].joined(separator: "|")
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                processPendingHydrationIfNeeded()
                synchronizeSnapshot()
            }
            .onChange(of: syncSignature) { _, _ in
                synchronizeSnapshot()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { @MainActor in
                    processPendingHydrationIfNeeded()
                    synchronizeSnapshot()
                }
            }
    }

    private var calendar: Calendar { .current }

    private var todayFoodEntries: [FoodEntry] {
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return allFoodEntries.filter { $0.date >= start && $0.date < end }
    }

    private var todayWaterEntries: [WaterEntry] {
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return allWaterEntries.filter { $0.date >= start && $0.date < end }
    }

    private var currentGoal: DailyGoal {
        goals.first ?? GoalService.defaultGoal()
    }

    private var foodSignature: String {
        let lastLogged = todayFoodEntries.map(\.date).max()?.timeIntervalSince1970 ?? 0
        let calories = Int(todayFoodEntries.reduce(0) { $0 + $1.calories }.rounded())
        return "food:\(todayFoodEntries.count):\(calories):\(Int(lastLogged))"
    }

    private var waterSignature: String {
        let lastLogged = todayWaterEntries.map(\.date).max()?.timeIntervalSince1970 ?? 0
        let total = Int(todayWaterEntries.reduce(0) { $0 + $1.amountOz }.rounded())
        return "water:\(todayWaterEntries.count):\(total):\(Int(lastLogged))"
    }

    private var goalSignature: String {
        [
            "goal",
            Int(currentGoal.calories.rounded()).description,
            Int(currentGoal.protein.rounded()).description,
            Int(currentGoal.carbs.rounded()).description,
            Int(currentGoal.fat.rounded()).description,
            Int(currentGoal.fiber.rounded()).description,
            activitySourceRaw,
            Int(activityReferenceActiveCalories.rounded()).description,
            Int(waterGoalOz.rounded()).description,
            weightUnitRaw
        ].joined(separator: ":")
    }

    private var weightSignature: String {
        let latestWeight = allWeightEntries.first?.weightLbs ?? 0
        let latestTime = allWeightEntries.first?.date.timeIntervalSince1970 ?? 0
        return "weight:\(allWeightEntries.count):\(latestWeight):\(Int(latestTime))"
    }

    private var garminSignature: String {
        let latestDate = garminManager.status.latestSummary?.date ?? "none"
        let latestActive = garminManager.status.latestSummary?.activeCalories ?? 0
        let avg = garminManager.averageActiveCalories ?? 0
        return "garmin:\(garminManager.isConfigured):\(garminManager.isConnected):\(Int(avg.rounded())):\(latestDate):\(Int(latestActive.rounded()))"
    }

    @MainActor
    private func processPendingHydrationIfNeeded() {
        let pending = NomvaPendingHydrationStore.drain()
        guard !pending.isEmpty else { return }

        for event in pending {
            let entry = WaterEntry(amountOz: event.amountOz)
            entry.date = event.loggedAt
            modelContext.insert(entry)
        }

        try? modelContext.save()
    }

    @MainActor
    private func synchronizeSnapshot() {
        let nutritionTotals = NutritionTotals.from(entries: todayFoodEntries)
        let todayHydrationOz = todayWaterEntries.reduce(0) { $0 + $1.amountOz }
        let activitySource = NomvaWidgetActivitySource(rawValue: activitySourceRaw) ?? .manual

        let measuredActiveCalories: Double?
        let activityState: NomvaWidgetActivityState

        switch activitySource {
        case .manual:
            measuredActiveCalories = nil
            activityState = .manual
        case .appleHealth:
            measuredActiveCalories = activityReferenceActiveCalories > 0 ? activityReferenceActiveCalories : nil
            activityState = measuredActiveCalories == nil ? .waiting : .ready
        case .garmin:
            measuredActiveCalories = garminManager.summary(for: .now)?.activeCalories
                ?? garminManager.averageActiveCalories
                ?? (activityReferenceActiveCalories > 0 ? activityReferenceActiveCalories : nil)

            if !garminManager.isConfigured {
                activityState = .setup
            } else if !garminManager.isConnected {
                activityState = .disconnected
            } else if measuredActiveCalories == nil {
                activityState = .waiting
            } else {
                activityState = .ready
            }
        }

        let adjustedGoalCalories: Double
        if activitySource != .manual,
           let measuredActiveCalories,
           activityReferenceActiveCalories > 0 {
            adjustedGoalCalories = GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: currentGoal.calories,
                dailyActiveCalories: measuredActiveCalories,
                referenceActiveCalories: activityReferenceActiveCalories
            )
        } else {
            adjustedGoalCalories = currentGoal.calories
        }

        let recentWeights = Array(allWeightEntries.prefix(7).reversed())
        let recentWeightValues = recentWeights.map(\.weightLbs)
        let sevenDayAverage = recentWeightValues.isEmpty
            ? nil
            : recentWeightValues.reduce(0, +) / Double(recentWeightValues.count)
        let latestWeight = allWeightEntries.first?.weightLbs
        let deltaFromAverage = latestWeight.flatMap { latest in
            sevenDayAverage.map { latest - $0 }
        }

        let weightTrend: NomvaWidgetWeightTrend
        if allWeightEntries.count >= analytics.minimumEntries {
            let insight = analytics.analyze(entries: allWeightEntries.map { ($0.date, $0.weightLbs) })
            switch insight.signal {
            case .losing, .losingSlowing:
                weightTrend = .down
            case .gaining, .gainingSlowing:
                weightTrend = .up
            case .plateau:
                weightTrend = .steady
            case .insufficient:
                weightTrend = .unknown
            }
        } else if let first = recentWeightValues.first, let last = recentWeightValues.last {
            let delta = last - first
            if abs(delta) < 0.2 {
                weightTrend = .steady
            } else {
                weightTrend = delta < 0 ? .down : .up
            }
        } else {
            weightTrend = .unknown
        }

        let snapshot = NomvaWidgetSnapshot(
            lastUpdatedAt: .now,
            today: NomvaTodayNutritionSnapshot(
                consumedCalories: nutritionTotals.calories,
                adjustedGoalCalories: adjustedGoalCalories,
                remainingCalories: adjustedGoalCalories - nutritionTotals.calories,
                mealCount: Set(todayFoodEntries.map(\.meal)).count,
                lastLoggedAt: todayFoodEntries.map(\.date).max(),
                proteinG: nutritionTotals.protein,
                proteinGoalG: currentGoal.protein,
                carbsG: nutritionTotals.carbs,
                carbsGoalG: currentGoal.carbs,
                fatG: nutritionTotals.fat,
                fatGoalG: currentGoal.fat
            ),
            hydration: NomvaHydrationSnapshot(
                totalOz: todayHydrationOz,
                goalOz: waterGoalOz
            ),
            activity: NomvaActivitySnapshot(
                source: activitySource,
                state: activityState,
                activeCalories: measuredActiveCalories,
                averageActiveCalories: activitySource == .garmin
                    ? garminManager.averageActiveCalories
                    : (activitySource == .appleHealth && activityReferenceActiveCalories > 0 ? activityReferenceActiveCalories : nil),
                steps: garminManager.summary(for: .now)?.steps,
                goalAdjustmentCalories: adjustedGoalCalories - currentGoal.calories,
                isConfigured: garminManager.isConfigured,
                isConnected: garminManager.isConnected
            ),
            weight: NomvaWeightSnapshot(
                latestWeightLbs: latestWeight,
                recentWeightsLbs: recentWeightValues,
                sevenDayAverageLbs: sevenDayAverage,
                deltaFromAverageLbs: deltaFromAverage,
                lastWeighInAt: allWeightEntries.first?.date,
                preferredUnit: NomvaWeightUnitSnapshot(rawValue: weightUnitRaw) ?? .lbs,
                trend: weightTrend
            )
        )

        NomvaWidgetSnapshotStore.writeSnapshot(snapshot)
    }
}
