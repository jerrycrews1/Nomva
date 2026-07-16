import Foundation
import SwiftData

@MainActor
final class SeedData {
    private static let seedMarker = "Screenshot Seed"

    static func seedAppStoreData(context: ModelContext) throws {
        try clearAppStoreData(context: context)
        configureAppDefaults()

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        context.insert(
            DailyGoal(
                calories: 2200,
                protein: 165,
                carbs: 215,
                fat: 75,
                fiber: 32
            )
        )

        let profile = UserProfile(
            biologicalSex: BiologicalSex.male.rawValue,
            birthYear: 1991,
            heightInches: 70,
            activityLevel: ActivityLevel.moderatelyActive.rawValue,
            weightGoal: WeightGoal.maintain.rawValue
        )
        profile.onboardingComplete = true
        context.insert(profile)

        for entry in sampleFoodEntries(relativeTo: today, calendar: calendar) {
            context.insert(entry)
        }

        for entry in sampleWaterEntries(relativeTo: today, calendar: calendar) {
            context.insert(entry)
        }

        for entry in sampleWeightEntries(relativeTo: today, calendar: calendar) {
            context.insert(entry)
        }

        for message in sampleChatMessages(relativeTo: today, calendar: calendar) {
            context.insert(message)
        }

        try context.save()
    }

    static func clearAppStoreData(context: ModelContext) throws {
        try context.delete(model: FoodEntry.self)
        try context.delete(model: WeightEntry.self)
        try context.delete(model: DailyGoal.self)
        try context.delete(model: ChatMessage.self)
        try context.delete(model: WaterEntry.self)
        try context.delete(model: UserProfile.self)
        try context.delete(model: LoggingSession.self)
        try context.delete(model: AgentTraceRecord.self)
        try context.delete(model: ResolvedFoodEvidence.self)
        try context.delete(model: CustomFood.self)
        try context.delete(model: MealTemplate.self)
        try context.save()
    }

    private static func configureAppDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "onboarding_complete")
        defaults.set(true, forKey: "goals_personalized")
        defaults.set(GoalActivitySource.manual.rawValue, forKey: "goal_activity_source")
        defaults.set(ActivityLevel.moderatelyActive.rawValue, forKey: "goal_manual_activity_level")
        defaults.set(0.0, forKey: "goal_activity_reference_active_calories")
        defaults.set(64.0, forKey: "water_goal_oz")
        defaults.set(WeightUnit.lbs.rawValue, forKey: "weight_unit")
    }

    private static func sampleFoodEntries(relativeTo today: Date, calendar: Calendar) -> [FoodEntry] {
        [
            foodEntry(
                name: "Greek Yogurt with Blueberries",
                brand: "Fage",
                meal: "breakfast",
                dayOffset: 0,
                hour: 8.0,
                portionGrams: 200,
                portionDescription: "1 cup",
                calories: 185,
                proteinG: 18,
                carbsG: 14,
                fatG: 0,
                fiberG: 2,
                sugarG: 10,
                sodiumMg: 70,
                calciumMg: 220,
                potassiumMg: 260,
                vitaminB12Mcg: 1.1,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Black Coffee",
                brand: nil,
                meal: "breakfast",
                dayOffset: 0,
                hour: 8.4,
                portionGrams: 240,
                portionDescription: "1 cup",
                calories: 5,
                proteinG: 0,
                carbsG: 0,
                fatG: 0,
                fiberG: 0,
                sugarG: 0,
                sodiumMg: 5,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Avocado Toast on Sourdough",
                brand: nil,
                meal: "lunch",
                dayOffset: 0,
                hour: 12.2,
                portionGrams: 165,
                portionDescription: "2 slices",
                calories: 345,
                proteinG: 9,
                carbsG: 38,
                fatG: 18,
                fiberG: 9,
                sugarG: 4,
                sodiumMg: 410,
                potassiumMg: 510,
                folateMcgDFE: 92,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Grilled Chicken Breast",
                brand: nil,
                meal: "lunch",
                dayOffset: 0,
                hour: 12.2,
                portionGrams: 130,
                portionDescription: "4.5 oz",
                calories: 215,
                proteinG: 38,
                carbsG: 0,
                fatG: 5,
                fiberG: 0,
                sugarG: 0,
                sodiumMg: 95,
                potassiumMg: 330,
                vitaminB12Mcg: 0.3,
                zincMg: 1.0,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Banana",
                brand: nil,
                meal: "snack",
                dayOffset: 0,
                hour: 15.1,
                portionGrams: 118,
                portionDescription: "1 medium",
                calories: 105,
                proteinG: 1,
                carbsG: 27,
                fatG: 0,
                fiberG: 3,
                sugarG: 14,
                sodiumMg: 1,
                potassiumMg: 420,
                vitaminCMg: 10,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Almonds",
                brand: "Blue Diamond",
                meal: "snack",
                dayOffset: 0,
                hour: 15.2,
                portionGrams: 28,
                portionDescription: "1 oz",
                calories: 170,
                proteinG: 6,
                carbsG: 6,
                fatG: 14,
                fiberG: 3,
                sugarG: 1,
                sodiumMg: 1,
                calciumMg: 75,
                ironMg: 1.1,
                magnesiumMg: 76,
                zincMg: 0.9,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Grilled Salmon Fillet",
                brand: nil,
                meal: "dinner",
                dayOffset: 0,
                hour: 19.0,
                portionGrams: 170,
                portionDescription: "6 oz",
                calories: 360,
                proteinG: 38,
                carbsG: 0,
                fatG: 22,
                fiberG: 0,
                sugarG: 0,
                sodiumMg: 95,
                vitaminDMcg: 15.0,
                potassiumMg: 620,
                vitaminB12Mcg: 4.5,
                magnesiumMg: 40,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Steamed Broccoli",
                brand: nil,
                meal: "dinner",
                dayOffset: 0,
                hour: 19.0,
                portionGrams: 150,
                portionDescription: "1.5 cups",
                calories: 85,
                proteinG: 6,
                carbsG: 14,
                fatG: 1,
                fiberG: 6,
                sugarG: 3,
                sodiumMg: 55,
                calciumMg: 90,
                vitaminCMg: 120,
                folateMcgDFE: 95,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Quinoa",
                brand: nil,
                meal: "dinner",
                dayOffset: 0,
                hour: 19.0,
                portionGrams: 185,
                portionDescription: "1 cup",
                calories: 220,
                proteinG: 8,
                carbsG: 39,
                fatG: 4,
                fiberG: 5,
                sugarG: 2,
                sodiumMg: 12,
                ironMg: 2.8,
                magnesiumMg: 118,
                zincMg: 1.9,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Overnight Oats",
                brand: nil,
                meal: "breakfast",
                dayOffset: -1,
                hour: 8.2,
                portionGrams: 220,
                portionDescription: "1 jar",
                calories: 310,
                proteinG: 15,
                carbsG: 42,
                fatG: 9,
                fiberG: 7,
                sugarG: 11,
                sodiumMg: 140,
                calciumMg: 180,
                ironMg: 3.2,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Turkey Sandwich",
                brand: nil,
                meal: "lunch",
                dayOffset: -1,
                hour: 12.4,
                portionGrams: 240,
                portionDescription: "1 sandwich",
                calories: 420,
                proteinG: 29,
                carbsG: 39,
                fatG: 16,
                fiberG: 5,
                sugarG: 5,
                sodiumMg: 720,
                ironMg: 2.6,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Chicken Burrito Bowl",
                brand: nil,
                meal: "dinner",
                dayOffset: -1,
                hour: 18.8,
                portionGrams: 410,
                portionDescription: "1 bowl",
                calories: 655,
                proteinG: 42,
                carbsG: 58,
                fatG: 25,
                fiberG: 11,
                sugarG: 6,
                sodiumMg: 860,
                potassiumMg: 980,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Protein Smoothie",
                brand: nil,
                meal: "breakfast",
                dayOffset: -2,
                hour: 7.9,
                portionGrams: 360,
                portionDescription: "1 smoothie",
                calories: 290,
                proteinG: 28,
                carbsG: 24,
                fatG: 8,
                fiberG: 5,
                sugarG: 15,
                sodiumMg: 180,
                calciumMg: 260,
                potassiumMg: 540,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Salmon Sushi Roll",
                brand: nil,
                meal: "lunch",
                dayOffset: -2,
                hour: 12.6,
                portionGrams: 190,
                portionDescription: "8 pieces",
                calories: 335,
                proteinG: 16,
                carbsG: 43,
                fatG: 10,
                fiberG: 2,
                sugarG: 5,
                sodiumMg: 620,
                vitaminB12Mcg: 2.4,
                today: today,
                calendar: calendar
            ),
            foodEntry(
                name: "Steak, Sweet Potato, and Green Beans",
                brand: nil,
                meal: "dinner",
                dayOffset: -2,
                hour: 19.1,
                portionGrams: 430,
                portionDescription: "1 plate",
                calories: 705,
                proteinG: 46,
                carbsG: 47,
                fatG: 32,
                fiberG: 8,
                sugarG: 10,
                sodiumMg: 540,
                ironMg: 4.7,
                potassiumMg: 1120,
                zincMg: 5.4,
                today: today,
                calendar: calendar
            )
        ]
    }

    private static func sampleWaterEntries(relativeTo today: Date, calendar: Calendar) -> [WaterEntry] {
        [
            waterEntry(dayOffset: 0, hour: 8.1, amountOz: 12, today: today, calendar: calendar),
            waterEntry(dayOffset: 0, hour: 10.7, amountOz: 8, today: today, calendar: calendar),
            waterEntry(dayOffset: 0, hour: 13.2, amountOz: 12, today: today, calendar: calendar),
            waterEntry(dayOffset: 0, hour: 16.9, amountOz: 8, today: today, calendar: calendar),
            waterEntry(dayOffset: 0, hour: 19.3, amountOz: 12, today: today, calendar: calendar),
            waterEntry(dayOffset: -1, hour: 18.0, amountOz: 64, today: today, calendar: calendar)
        ]
    }

    private static func sampleWeightEntries(relativeTo today: Date, calendar: Calendar) -> [WeightEntry] {
        let weights: [Double] = [
            186.8, 186.5, 186.4, 186.2, 186.0, 185.8, 185.9, 185.6, 185.4, 185.2,
            185.0, 184.8, 184.9, 184.6, 184.4, 184.2, 184.0, 183.8, 183.9, 183.6,
            183.4, 183.1, 182.9, 182.7, 182.5, 182.3, 182.1, 181.9, 181.7, 181.5
        ]

        return weights.enumerated().map { index, value in
            let dayOffset = index - (weights.count - 1)
            let date = date(dayOffset: dayOffset, hour: 8.3, relativeTo: today, calendar: calendar)
            return WeightEntry(date: date, weightLbs: value)
        }
    }

    private static func sampleChatMessages(relativeTo today: Date, calendar: Calendar) -> [ChatMessage] {
        [
            chatMessage(
                role: "user",
                content: "For breakfast I had Greek yogurt with blueberries and a black coffee.",
                dayOffset: 0,
                hour: 8.5,
                today: today,
                calendar: calendar
            ),
            chatMessage(
                role: "assistant",
                content: "Logged. Breakfast is in for 190 calories.",
                dayOffset: 0,
                hour: 8.55,
                today: today,
                calendar: calendar
            ),
            chatMessage(
                role: "user",
                content: "Add avocado toast and grilled chicken for lunch.",
                dayOffset: 0,
                hour: 12.3,
                today: today,
                calendar: calendar
            ),
            chatMessage(
                role: "assistant",
                content: "Done. Lunch adds 560 calories and keeps you on track for the day.",
                dayOffset: 0,
                hour: 12.35,
                today: today,
                calendar: calendar
            ),
            chatMessage(
                role: "user",
                content: "How many calories do I have left?",
                dayOffset: 0,
                hour: 15.3,
                today: today,
                calendar: calendar
            ),
            chatMessage(
                role: "assistant",
                content: "You have 815 calories left today, with plenty of protein still open for dinner.",
                dayOffset: 0,
                hour: 15.35,
                today: today,
                calendar: calendar
            )
        ]
    }

    private static func foodEntry(
        name: String,
        brand: String?,
        meal: String,
        dayOffset: Int,
        hour: Double,
        portionGrams: Double,
        portionDescription: String,
        calories: Double,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        fiberG: Double,
        sugarG: Double,
        sodiumMg: Double,
        vitaminDMcg: Double? = nil,
        calciumMg: Double? = nil,
        ironMg: Double? = nil,
        potassiumMg: Double? = nil,
        vitaminCMg: Double? = nil,
        vitaminB12Mcg: Double? = nil,
        folateMcgDFE: Double? = nil,
        magnesiumMg: Double? = nil,
        zincMg: Double? = nil,
        today: Date,
        calendar: Calendar
    ) -> FoodEntry {
        return FoodEntry(
            name: name,
            brand: brand,
            meal: meal,
            date: date(dayOffset: dayOffset, hour: hour, relativeTo: today, calendar: calendar),
            portionGrams: portionGrams,
            portionDescription: portionDescription,
            servings: 1.0,
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            sugarG: sugarG,
            sodiumMg: sodiumMg,
            vitaminDMcg: vitaminDMcg,
            calciumMg: calciumMg,
            ironMg: ironMg,
            potassiumMg: potassiumMg,
            vitaminCMg: vitaminCMg,
            vitaminB12Mcg: vitaminB12Mcg,
            folateMcgDFE: folateMcgDFE,
            magnesiumMg: magnesiumMg,
            zincMg: zincMg,
            rawUserInput: seedMarker
        )
    }

    private static func waterEntry(
        dayOffset: Int,
        hour: Double,
        amountOz: Double,
        today: Date,
        calendar: Calendar
    ) -> WaterEntry {
        let entry = WaterEntry(amountOz: amountOz)
        entry.date = date(dayOffset: dayOffset, hour: hour, relativeTo: today, calendar: calendar)
        return entry
    }

    private static func chatMessage(
        role: String,
        content: String,
        dayOffset: Int,
        hour: Double,
        today: Date,
        calendar: Calendar
    ) -> ChatMessage {
        let timestamp = date(dayOffset: dayOffset, hour: hour, relativeTo: today, calendar: calendar)
        return ChatMessage(
            role: role,
            content: content,
            timestamp: timestamp,
            dayDate: calendar.startOfDay(for: timestamp)
        )
    }

    private static func date(
        dayOffset: Int,
        hour: Double,
        relativeTo today: Date,
        calendar: Calendar
    ) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
        return day.addingTimeInterval(hour * 3600)
    }
}
