import SwiftData
import Foundation

// MARK: - Food Entry (logged meals)
@Model
class FoodEntry {
    var id: UUID = UUID()
    var name: String = ""
    var brand: String?
    var meal: String = "snack"
    var date: Date = Date.now
    var portionGrams: Double = 0
    var portionDescription: String = ""
    var servings: Double = 1.0
    var servingUnit: String = "serving"
    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var fiberG: Double = 0
    var sugarG: Double = 0
    var sodiumMg: Double = 0
    var saturatedFatG: Double?
    var transFatG: Double?
    var cholesterolMg: Double?
    var addedSugarG: Double?
    var vitaminDMcg: Double?
    var calciumMg: Double?
    var ironMg: Double?
    var potassiumMg: Double?
    var vitaminAMcgRAE: Double?
    var vitaminCMg: Double?
    var vitaminB12Mcg: Double?
    var folateMcgDFE: Double?
    var magnesiumMg: Double?
    var zincMg: Double?
    var caloriesPer100g: Double = 0
    var proteinPer100g: Double = 0
    var carbsPer100g: Double = 0
    var fatPer100g: Double = 0
    var fiberPer100g: Double = 0
    var sugarPer100g: Double = 0
    var sodiumPer100g: Double = 0
    var saturatedFatPer100g: Double?
    var transFatPer100g: Double?
    var cholesterolPer100g: Double?
    var addedSugarPer100g: Double?
    var vitaminDPer100g: Double?
    var calciumPer100g: Double?
    var ironPer100g: Double?
    var potassiumPer100g: Double?
    var vitaminAPer100g: Double?
    var vitaminCPer100g: Double?
    var vitaminB12Per100g: Double?
    var folatePer100g: Double?
    var magnesiumPer100g: Double?
    var zincPer100g: Double?
    var rawUserInput: String = ""
    var fdcId: Int?
    var foodDatabaseId: Int?
    var source: String?
    var barcode: String?
    var isFavorite: Bool = false

    init(name: String, brand: String? = nil, meal: String, date: Date = .now,
         portionGrams: Double, portionDescription: String,
         servings: Double = 1.0, servingUnit: String = "serving",
         calories: Double, proteinG: Double, carbsG: Double, fatG: Double,
         fiberG: Double, sugarG: Double = 0, sodiumMg: Double = 0,
         saturatedFatG: Double? = nil, transFatG: Double? = nil,
         cholesterolMg: Double? = nil, addedSugarG: Double? = nil,
         vitaminDMcg: Double? = nil, calciumMg: Double? = nil,
         ironMg: Double? = nil, potassiumMg: Double? = nil,
         vitaminAMcgRAE: Double? = nil, vitaminCMg: Double? = nil,
         vitaminB12Mcg: Double? = nil, folateMcgDFE: Double? = nil,
         magnesiumMg: Double? = nil, zincMg: Double? = nil,
         caloriesPer100g: Double = 0, proteinPer100g: Double = 0,
         carbsPer100g: Double = 0, fatPer100g: Double = 0, fiberPer100g: Double = 0,
         sugarPer100g: Double = 0, sodiumPer100g: Double = 0,
         saturatedFatPer100g: Double? = nil, transFatPer100g: Double? = nil,
         cholesterolPer100g: Double? = nil, addedSugarPer100g: Double? = nil,
         vitaminDPer100g: Double? = nil, calciumPer100g: Double? = nil,
         ironPer100g: Double? = nil, potassiumPer100g: Double? = nil,
         vitaminAPer100g: Double? = nil, vitaminCPer100g: Double? = nil,
         vitaminB12Per100g: Double? = nil, folatePer100g: Double? = nil,
         magnesiumPer100g: Double? = nil, zincPer100g: Double? = nil,
         rawUserInput: String, fdcId: Int? = nil,
         foodDatabaseId: Int? = nil, source: String? = nil, barcode: String? = nil) {
        self.id = UUID()
        self.name = name
        self.brand = brand
        self.meal = meal
        self.date = date
        self.portionGrams = portionGrams
        self.portionDescription = portionDescription
        self.servings = servings
        self.servingUnit = servingUnit
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.saturatedFatG = saturatedFatG
        self.transFatG = transFatG
        self.cholesterolMg = cholesterolMg
        self.addedSugarG = addedSugarG
        self.vitaminDMcg = vitaminDMcg
        self.calciumMg = calciumMg
        self.ironMg = ironMg
        self.potassiumMg = potassiumMg
        self.vitaminAMcgRAE = vitaminAMcgRAE
        self.vitaminCMg = vitaminCMg
        self.vitaminB12Mcg = vitaminB12Mcg
        self.folateMcgDFE = folateMcgDFE
        self.magnesiumMg = magnesiumMg
        self.zincMg = zincMg
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.carbsPer100g = carbsPer100g
        self.fatPer100g = fatPer100g
        self.fiberPer100g = fiberPer100g
        self.sugarPer100g = sugarPer100g
        self.sodiumPer100g = sodiumPer100g
        self.saturatedFatPer100g = saturatedFatPer100g
        self.transFatPer100g = transFatPer100g
        self.cholesterolPer100g = cholesterolPer100g
        self.addedSugarPer100g = addedSugarPer100g
        self.vitaminDPer100g = vitaminDPer100g
        self.calciumPer100g = calciumPer100g
        self.ironPer100g = ironPer100g
        self.potassiumPer100g = potassiumPer100g
        self.vitaminAPer100g = vitaminAPer100g
        self.vitaminCPer100g = vitaminCPer100g
        self.vitaminB12Per100g = vitaminB12Per100g
        self.folatePer100g = folatePer100g
        self.magnesiumPer100g = magnesiumPer100g
        self.zincPer100g = zincPer100g
        self.rawUserInput = rawUserInput
        self.fdcId = fdcId
        self.foodDatabaseId = foodDatabaseId
        self.source = source
        self.barcode = barcode
        self.isFavorite = false
    }
}

// MARK: - Daily Goal
@Model
class DailyGoal {
    var id: UUID = UUID()
    var calories: Double = 2000
    var protein: Double = 150
    var carbs: Double = 250
    var fat: Double = 65
    var fiber: Double = 25
    var createdAt: Date = Date.now
    var isActive: Bool = true

    init(calories: Double, protein: Double, carbs: Double,
         fat: Double, fiber: Double = 25) {
        self.id = UUID()
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.createdAt = .now
        self.isActive = true
    }
}

// MARK: - Weight Entry
@Model
class WeightEntry {
    var id: UUID = UUID()
    var date: Date = Date.now
    var weightLbs: Double = 160
    var note: String?

    init(date: Date = .now, weightLbs: Double, note: String? = nil) {
        self.id = UUID()
        self.date = date
        self.weightLbs = weightLbs
        self.note = note
    }

    var weightKg: Double { weightLbs * 0.453592 }
}

// MARK: - Chat Message
@Model
class ChatMessage {
    var id: UUID = UUID()
    var role: String = "user"
    var content: String = ""
    var timestamp: Date = Date.now
    var dayDate: Date = Date.now

    init(role: String, content: String, timestamp: Date = .now, dayDate: Date? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.dayDate = dayDate ?? Calendar.current.startOfDay(for: timestamp)
    }
}

// MARK: - Custom Food
@Model
class CustomFood {
    var id: UUID = UUID()
    var name: String = ""
    var brand: String?
    var servingDesc: String = "serving"
    var servingGrams: Double = 100
    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var fiberG: Double = 0
    var barcode: String?
    var createdAt: Date = Date.now

    init(name: String, brand: String? = nil, servingDesc: String,
         servingGrams: Double, calories: Double, proteinG: Double,
         carbsG: Double, fatG: Double, fiberG: Double, barcode: String? = nil) {
        self.id = UUID()
        self.name = name
        self.brand = brand
        self.servingDesc = servingDesc
        self.servingGrams = servingGrams
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.barcode = barcode
        self.createdAt = .now
    }
}

// MARK: - User Profile
@Model
class UserProfile {
    var id: UUID = UUID()
    var biologicalSex: String = "notSpecified"
    var birthYear: Int = 1990
    var heightInches: Int = 70
    var activityLevel: String = "moderatelyActive"
    var weightGoal: String = "maintain"
    var onboardingComplete: Bool = false
    var createdAt: Date = Date.now

    init(biologicalSex: String, birthYear: Int, heightInches: Int,
         activityLevel: String, weightGoal: String) {
        self.id = UUID()
        self.biologicalSex = biologicalSex
        self.birthYear = birthYear
        self.heightInches = heightInches
        self.activityLevel = activityLevel
        self.weightGoal = weightGoal
        self.onboardingComplete = false
        self.createdAt = .now
    }
}

// MARK: - Water Entry
@Model
class WaterEntry {
    var id: UUID = UUID()
    var date: Date = Date.now
    var amountOz: Double = 8

    init(amountOz: Double) {
        self.id = UUID()
        self.date = .now
        self.amountOz = amountOz
    }
}

// MARK: - AI Models (Codable)
struct CandidateGroupSnapshot: Codable {
    var query: String
    var description: String
    var candidateIds: [String]
}

struct AgentTaskState: Codable {
    var taskId: UUID
    var status: String
    var intent: String?
    var originalUserMessage: String
    var latestUserMessage: String
    var meal: String?
    var pendingDescriptions: [String]
    var unresolvedSlots: [String]
    var lastQuestion: String?
    var correctionTargetName: String?
    var lastToolContext: String?
    var candidateGroups: [CandidateGroupSnapshot]
}

// MARK: - Other Records
@Model
class LoggingSession {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var dayDate: Date = Date.now
    var status: String = ""
    var serializedState: String = "{}"

    init(dayDate: Date, state: AgentTaskState) {
        self.id = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.dayDate = dayDate
        self.status = state.status
        self.serializedState = LoggingSession.encode(state)
    }

    var decodedState: AgentTaskState? {
        guard let data = serializedState.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentTaskState.self, from: data)
    }

    func apply(state: AgentTaskState) {
        self.updatedAt = .now
        self.status = state.status
        self.serializedState = LoggingSession.encode(state)
    }

    private static func encode(_ state: AgentTaskState) -> String {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

@Model
class AgentTraceRecord {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var dayDate: Date = Date.now
    var userMessage: String = ""
    var detectedIntent: String = ""
    var providerType: String = ""
    var usedFallback: Bool = false
    var rawModelAction: String?
    var routedAction: String?
    var finalAction: String = ""
    var validationSummary: String = ""
    var searchSummary: String?
    var candidateSummary: String?
    var rawModelResponse: String?
    var finalReply: String?

    init(
        dayDate: Date,
        userMessage: String,
        detectedIntent: String,
        providerType: String,
        usedFallback: Bool,
        rawModelAction: String?,
        routedAction: String?,
        finalAction: String,
        validationSummary: String,
        searchSummary: String?,
        candidateSummary: String?,
        rawModelResponse: String?,
        finalReply: String?
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.dayDate = dayDate
        self.userMessage = userMessage
        self.detectedIntent = detectedIntent
        self.providerType = providerType
        self.usedFallback = usedFallback
        self.rawModelAction = rawModelAction
        self.routedAction = routedAction
        self.finalAction = finalAction
        self.validationSummary = validationSummary
        self.searchSummary = searchSummary
        self.candidateSummary = candidateSummary
        self.rawModelResponse = rawModelResponse
        self.finalReply = finalReply
    }
}

@Model
class ResolvedFoodEvidence {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var dayDate: Date = Date.now
    var foodEntryId: UUID = UUID()
    var sourceType: String = ""
    var fdcId: Int?
    var matchedName: String = ""
    var matchedBrand: String?
    var searchTerms: String = ""
    var candidateSummary: String = ""
    var resolutionConfidence: Double = 0
    var wasClarified: Bool = false

    init(
        dayDate: Date,
        foodEntryId: UUID,
        sourceType: String,
        fdcId: Int?,
        matchedName: String,
        matchedBrand: String?,
        searchTerms: String,
        candidateSummary: String,
        resolutionConfidence: Double,
        wasClarified: Bool
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.dayDate = dayDate
        self.foodEntryId = foodEntryId
        self.sourceType = sourceType
        self.fdcId = fdcId
        self.matchedName = matchedName
        self.matchedBrand = matchedBrand
        self.searchTerms = searchTerms
        self.candidateSummary = candidateSummary
        self.resolutionConfidence = resolutionConfidence
        self.wasClarified = wasClarified
    }
}

@Model
class MealTemplate {
    var id: UUID = UUID()
    var name: String = ""
    var items: [TemplateItem] = []
    var createdAt: Date = Date.now

    struct TemplateItem: Codable {
        var foodName: String
        var portionGrams: Double
        var calories: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var brand: String?
        var portionDescription: String?
        var servings: Double?
        var servingUnit: String?
        var fiberG: Double?
        var source: String?
        var fdcId: Int?
        var foodDatabaseId: Int?
        var barcode: String?
    }

    init(name: String, items: [TemplateItem] = []) {
        self.id = UUID()
        self.name = name
        self.items = items
        self.createdAt = .now
    }
}

// MARK: - Nutrition Totals (computed)
struct NutritionTotals {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sugar: Double = 0
    var sodium: Double = 0
    var saturatedFat: Double = 0
    var transFat: Double = 0
    var cholesterol: Double = 0
    var addedSugar: Double = 0
    var vitaminD: Double = 0
    var calcium: Double = 0
    var iron: Double = 0
    var potassium: Double = 0
    var vitaminA: Double = 0
    var vitaminC: Double = 0
    var vitaminB12: Double = 0
    var folate: Double = 0
    var magnesium: Double = 0
    var zinc: Double = 0

    static func from(entries: [FoodEntry]) -> NutritionTotals {
        entries.reduce(into: NutritionTotals()) { totals, entry in
            totals.calories += entry.calories
            totals.protein  += entry.proteinG
            totals.carbs    += entry.carbsG
            totals.fat      += entry.fatG
            totals.fiber    += entry.fiberG
            totals.sugar    += entry.sugarG
            totals.sodium   += entry.sodiumMg
            totals.saturatedFat += entry.saturatedFatG ?? 0
            totals.transFat += entry.transFatG ?? 0
            totals.cholesterol += entry.cholesterolMg ?? 0
            totals.addedSugar += entry.addedSugarG ?? 0
            totals.vitaminD += entry.vitaminDMcg ?? 0
            totals.calcium += entry.calciumMg ?? 0
            totals.iron += entry.ironMg ?? 0
            totals.potassium += entry.potassiumMg ?? 0
            totals.vitaminA += entry.vitaminAMcgRAE ?? 0
            totals.vitaminC += entry.vitaminCMg ?? 0
            totals.vitaminB12 += entry.vitaminB12Mcg ?? 0
            totals.folate += entry.folateMcgDFE ?? 0
            totals.magnesium += entry.magnesiumMg ?? 0
            totals.zinc += entry.zincMg ?? 0
        }
    }
}

// MARK: - Supporting Enums

enum BiologicalSex: String, CaseIterable, Codable {
    case male, female, notSpecified

    var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .notSpecified: return "Prefer not to say"
        }
    }
}

enum ActivityLevel: String, CaseIterable, Codable {
    case sedentary, lightlyActive, moderatelyActive, veryActive, extraActive

    var multiplier: Double {
        switch self {
        case .sedentary:        return 1.2
        case .lightlyActive:    return 1.375
        case .moderatelyActive: return 1.55
        case .veryActive:       return 1.725
        case .extraActive:      return 1.9
        }
    }

    var displayName: String {
        switch self {
        case .sedentary:        return "Sedentary"
        case .lightlyActive:    return "Lightly Active"
        case .moderatelyActive: return "Moderately Active"
        case .veryActive:       return "Very Active"
        case .extraActive:      return "Extra Active"
        }
    }

    var description: String {
        switch self {
        case .sedentary:        return "Desk job, little or no exercise"
        case .lightlyActive:    return "Light exercise 1–3 days per week"
        case .moderatelyActive: return "Moderate exercise 3–5 days per week"
        case .veryActive:       return "Hard exercise 6–7 days per week"
        case .extraActive:      return "Physical job or twice-daily training"
        }
    }
}

enum GoalActivitySource: String, CaseIterable, Codable {
    case manual
    case appleHealth
    case garmin

    var displayName: String {
        switch self {
        case .manual:
            return "Manual Estimate"
        case .appleHealth:
            return "Apple Health"
        case .garmin:
            return "Garmin Connect"
        }
    }

    var subtitle: String {
        switch self {
        case .manual:
            return "Use your usual day-to-day activity level as a starting estimate."
        case .appleHealth:
            return "Use recent active calories from the Apple Health app."
        case .garmin:
            return "Use Garmin Connect activity synced through Nomva Cloud."
        }
    }

    var systemImage: String {
        switch self {
        case .manual:
            return "slider.horizontal.3"
        case .appleHealth:
            return "heart.text.square.fill"
        case .garmin:
            return "dot.radiowaves.left.and.right"
        }
    }
}

struct GoalActivityProfile {
    var source: GoalActivitySource
    var manualLevel: ActivityLevel?
    var averageActiveCalories: Double?

    static func manual(_ level: ActivityLevel) -> GoalActivityProfile {
        GoalActivityProfile(source: .manual, manualLevel: level, averageActiveCalories: nil)
    }

    static func measured(_ calories: Double, source: GoalActivitySource) -> GoalActivityProfile {
        GoalActivityProfile(source: source, manualLevel: nil, averageActiveCalories: calories)
    }
}

enum WeightGoal: String, CaseIterable, Codable {
    case loseWeight, maintain, gainMuscle

    var displayName: String {
        switch self {
        case .loseWeight:  return "Lose Weight"
        case .maintain:    return "Maintain"
        case .gainMuscle:  return "Build Muscle"
        }
    }
}

enum WeightUnit: String, Codable {
    case lbs, kg
}
