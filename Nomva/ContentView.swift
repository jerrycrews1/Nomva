import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab: Tab = Self.initialTab
    @StateObject private var subManager = SubscriptionManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var routeCenter: NomvaRouteCenter
    @EnvironmentObject private var garminManager: GarminManager

    enum Tab {
        case chat, log, weight, settings
    }

    private static var initialTab: Tab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-NomvaStartSettings") { return .settings }
        if arguments.contains("-NomvaStartLog") { return .log }
        if arguments.contains("-NomvaStartWeight") { return .weight }
        #endif
        return .chat
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Group {
                if subManager.canUseAI {
                    ChatView()
                } else {
                    PaywallView()
                }
            }
            .tabItem {
                Label("AI Chat", systemImage: "sparkles")
            }
            .tag(Tab.chat)

            DailyLogView()
                .tabItem {
                    Label("Log", systemImage: "list.bullet.clipboard")
                }
                .tag(Tab.log)

            WeightLoggingView()
                .tabItem {
                    Label("Weight", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(Tab.weight)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .tint(NomvaTheme.accent)
        .background {
            ZStack {
                NomvaWidgetSyncBridge()
                FoodEntryMicronutrientBackfillView()
            }
            .allowsHitTesting(false)
        }
        .task {
            routeCenter.consumeStoredRouteIfNeeded()
            await garminManager.refreshIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            routeCenter.consumeStoredRouteIfNeeded()
            Task { await garminManager.refresh() }
        }
        .onReceive(routeCenter.$currentRoute.compactMap { $0 }) { route in
            selectedTab = tab(for: route)
        }
    }

    private func tab(for route: NomvaWidgetRoute) -> Tab {
        switch route {
        case .todayLog, .hydration, .manualSearch:
            return .log
        case .chat, .barcode:
            return .chat
        case .weight, .weightLog:
            return .weight
        case .goals:
            return .settings
        }
    }
}

private struct FoodEntryMicronutrientBackfillView: View {
    @Query(sort: \FoodEntry.date) private var entries: [FoodEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRun = false

    var body: some View {
        Color.clear
            .task {
                await backfillIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await backfillIfNeeded() }
            }
    }

    @MainActor
    private func backfillIfNeeded() async {
        guard !didRun else { return }
        didRun = true

        let candidates = entries
            .filter(needsMicronutrientBackfill)
            .prefix(300)

        guard !candidates.isEmpty else { return }

        var updatedCount = 0
        for entry in candidates {
            guard let food = await matchingFood(for: entry) else { continue }
            applyMicronutrients(from: food, to: entry)
            updatedCount += 1
        }

        if updatedCount > 0 {
            try? modelContext.save()
        }
    }

    private func needsMicronutrientBackfill(_ entry: FoodEntry) -> Bool {
        let hasMissingCoreMicros = entry.saturatedFatG == nil
            || entry.addedSugarG == nil
            || entry.vitaminDMcg == nil
            || entry.calciumMg == nil
            || entry.ironMg == nil
            || entry.potassiumMg == nil

        let hasLookupKey = entry.foodDatabaseId != nil || entry.fdcId != nil || entry.barcode != nil
        return hasMissingCoreMicros && hasLookupKey
    }

    private func matchingFood(for entry: FoodEntry) async -> FoodItem? {
        if let foodDatabaseId = entry.foodDatabaseId,
           let food = await DatabaseManager.shared.food(byRowId: foodDatabaseId) {
            return food
        }

        if let fdcId = entry.fdcId,
           let food = await DatabaseManager.shared.food(byFdcId: fdcId) {
            return food
        }

        if let barcode = entry.barcode,
           let food = await DatabaseManager.shared.food(byBarcode: barcode) {
            return food
        }

        return nil
    }

    private func applyMicronutrients(from food: FoodItem, to entry: FoodEntry) {
        let grams = entry.portionGrams > 0 ? entry.portionGrams : (food.servingGrams ?? 100)
        let nutrition = food.scaled(to: grams)
        let per100 = food.per100g

        entry.saturatedFatG = entry.saturatedFatG ?? nutrition.saturatedFat
        entry.transFatG = entry.transFatG ?? nutrition.transFat
        entry.cholesterolMg = entry.cholesterolMg ?? nutrition.cholesterol
        entry.addedSugarG = entry.addedSugarG ?? nutrition.addedSugar
        entry.vitaminDMcg = entry.vitaminDMcg ?? nutrition.vitaminD
        entry.calciumMg = entry.calciumMg ?? nutrition.calcium
        entry.ironMg = entry.ironMg ?? nutrition.iron
        entry.potassiumMg = entry.potassiumMg ?? nutrition.potassium
        entry.vitaminAMcgRAE = entry.vitaminAMcgRAE ?? nutrition.vitaminA
        entry.vitaminCMg = entry.vitaminCMg ?? nutrition.vitaminC
        entry.vitaminB12Mcg = entry.vitaminB12Mcg ?? nutrition.vitaminB12
        entry.folateMcgDFE = entry.folateMcgDFE ?? nutrition.folate
        entry.magnesiumMg = entry.magnesiumMg ?? nutrition.magnesium
        entry.zincMg = entry.zincMg ?? nutrition.zinc

        entry.saturatedFatPer100g = entry.saturatedFatPer100g ?? per100.saturatedFat
        if entry.sugarPer100g == 0 { entry.sugarPer100g = per100.sugar }
        if entry.sodiumPer100g == 0 { entry.sodiumPer100g = per100.sodium }
        entry.transFatPer100g = entry.transFatPer100g ?? per100.transFat
        entry.cholesterolPer100g = entry.cholesterolPer100g ?? per100.cholesterol
        entry.addedSugarPer100g = entry.addedSugarPer100g ?? per100.addedSugar
        entry.vitaminDPer100g = entry.vitaminDPer100g ?? per100.vitaminD
        entry.calciumPer100g = entry.calciumPer100g ?? per100.calcium
        entry.ironPer100g = entry.ironPer100g ?? per100.iron
        entry.potassiumPer100g = entry.potassiumPer100g ?? per100.potassium
        entry.vitaminAPer100g = entry.vitaminAPer100g ?? per100.vitaminA
        entry.vitaminCPer100g = entry.vitaminCPer100g ?? per100.vitaminC
        entry.vitaminB12Per100g = entry.vitaminB12Per100g ?? per100.vitaminB12
        entry.folatePer100g = entry.folatePer100g ?? per100.folate
        entry.magnesiumPer100g = entry.magnesiumPer100g ?? per100.magnesium
        entry.zincPer100g = entry.zincPer100g ?? per100.zinc

        entry.foodDatabaseId = entry.foodDatabaseId ?? food.id
        entry.fdcId = entry.fdcId ?? food.fdcId
        entry.source = entry.source ?? food.source
        entry.barcode = entry.barcode ?? food.barcode
    }
}

#Preview {
    ContentView()
        .environmentObject(GarminManager.shared)
        .environmentObject(NomvaRouteCenter.shared)
}
