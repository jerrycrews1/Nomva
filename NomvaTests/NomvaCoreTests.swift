import Foundation
import SwiftData
import Testing
@testable import Nomva

@Suite("Nomva core behavior")
struct NomvaCoreTests {
    @Test("Mifflin-St Jeor uses the supplied body data")
    func bmrCalculation() {
        let result = GoalService.calculateBMR(
            weightLbs: 160,
            heightTotalInches: 69,
            ageYears: 30,
            sex: .male
        )

        #expect(abs(result - 1_675.65) < 0.5)
    }

    @Test("Measured activity is added once to resting calories")
    func measuredMaintenance() {
        let bmr = GoalService.calculateBMR(
            weightLbs: 160,
            heightTotalInches: 69,
            ageYears: 30,
            sex: .male
        )
        let maintenance = GoalService.calculateMaintenanceCalories(
            weightLbs: 160,
            heightTotalInches: 69,
            ageYears: 30,
            sex: .male,
            activityProfile: .measured(400, source: .appleHealth)
        )

        #expect(abs(maintenance - (bmr + 400)) < 0.01)
    }

    @Test("Today earns only activity above the completed-day baseline")
    func sameDayActivityAdjustment() {
        #expect(GoalService.sameDayAdjustedCalories(
            baseGoalCalories: 2_000,
            currentDayActiveCalories: 700,
            rollingAverageActiveCalories: 400,
            referenceActiveCalories: 400
        ) == 2_300)

        #expect(GoalService.sameDayAdjustedCalories(
            baseGoalCalories: 2_000,
            currentDayActiveCalories: 200,
            rollingAverageActiveCalories: 400,
            referenceActiveCalories: 400
        ) == 2_000)
    }

    @Test("Suggested macros reconcile to the calorie target")
    func macroReconciliation() {
        let target = 2_100.0
        let macros = GoalService.suggestMacros(
            calories: target,
            weightLbs: 180,
            goal: .maintain
        )
        let macroCalories = macros.protein * 4 + macros.carbs * 4 + macros.fat * 9

        #expect(abs(macroCalories - target) < 0.01)
        #expect(macros.protein > 0)
        #expect(macros.carbs >= 50)
        #expect(macros.fat > 0)
    }

    @Test("Meal storage normalization is stable")
    func mealNormalization() {
        #expect(MealCategory(storedValue: " Breakfast ") == .breakfast)
        #expect(MealCategory(storedValue: "LUNCH") == .lunch)
        #expect(MealCategory(storedValue: "unknown") == .snack)
    }

    @Test("Nutrition totals include every logged item exactly once")
    @MainActor
    func nutritionTotals() {
        let entries = [
            food(name: "Yogurt", calories: 110, protein: 15, carbs: 8, fat: 2),
            food(name: "Blueberries", calories: 84, protein: 1, carbs: 21, fat: 0.5),
        ]
        let totals = NutritionTotals.from(entries: entries)

        #expect(totals.calories == 194)
        #expect(totals.protein == 16)
        #expect(totals.carbs == 29)
        #expect(totals.fat == 2.5)
    }

    @Test("StoreKit implementation details never reach user-facing errors")
    func subscriptionErrorCopy() {
        let restore = SubscriptionErrorCopy.message(
            domain: "SKInternalErrorDomain",
            operation: .restore
        )
        let network = SubscriptionErrorCopy.message(
            domain: NSURLErrorDomain,
            operation: .purchase
        )

        #expect(restore == "The App Store couldn't restore purchases right now. Please try again.")
        #expect(!restore.localizedCaseInsensitiveContains("SKInternal"))
        #expect(network == "Check your internet connection and try again.")
    }

    @Test("Sync archives round-trip user records without loss")
    @MainActor
    func syncArchiveRoundTrip() throws {
        let source = try inMemoryContainer()
        let sourceContext = ModelContext(source)
        let entry = food(name: "Greek yogurt", calories: 110, protein: 15, carbs: 8, fat: 2)
        entry.meal = "breakfast"
        sourceContext.insert(entry)
        sourceContext.insert(WaterEntry(amountOz: 20))
        sourceContext.insert(DailyGoal(calories: 2_000, protein: 150, carbs: 220, fat: 67))
        try sourceContext.save()

        let archive = try SyncMigrationService.captureArchive(from: source, storeKind: .local)
        let destination = try inMemoryContainer()
        let counts = try SyncMigrationService.merge(archive: archive, into: destination)
        let destinationContext = ModelContext(destination)

        #expect(archive.totalRecordCount == 3)
        #expect(counts.inserted == 3)
        #expect(try destinationContext.fetch(FetchDescriptor<FoodEntry>()).first?.name == "Greek yogurt")
        #expect(try destinationContext.fetch(FetchDescriptor<WaterEntry>()).first?.amountOz == 20)
        #expect(try destinationContext.fetch(FetchDescriptor<DailyGoal>()).first?.calories == 2_000)
    }

    @MainActor
    private func food(
        name: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) -> FoodEntry {
        FoodEntry(
            name: name,
            meal: "snack",
            portionGrams: 100,
            portionDescription: "1 serving",
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fiberG: 0,
            rawUserInput: name
        )
    }

    @MainActor
    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            FoodEntry.self, DailyGoal.self, WeightEntry.self,
            ChatMessage.self, CustomFood.self, UserProfile.self,
            MealTemplate.self, WaterEntry.self, LoggingSession.self,
            AgentTraceRecord.self, ResolvedFoodEvidence.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
