import SQLite3
import Foundation

struct FoodItem: Identifiable, Codable, Hashable {
    let id: Int
    let fdcId: Int?
    let name: String
    let brand: String?
    let source: String?
    let servingGrams: Double?
    let servingDesc: String?
    let caloriesPerServing: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let fiberG: Double
    let sugarG: Double
    let sodiumMg: Double
    let barcode: String?

    init(
        id: Int,
        fdcId: Int? = nil,
        name: String,
        brand: String? = nil,
        source: String? = nil,
        servingGrams: Double? = nil,
        servingDesc: String? = nil,
        caloriesPerServing: Double,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        fiberG: Double,
        sugarG: Double,
        sodiumMg: Double,
        barcode: String? = nil
    ) {
        self.id = id
        self.fdcId = fdcId
        self.name = name
        self.brand = brand
        self.source = source
        self.servingGrams = servingGrams
        self.servingDesc = servingDesc
        self.caloriesPerServing = caloriesPerServing
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.barcode = barcode
    }

    // Convenience: nutrition scaled to a custom gram amount
    func scaled(to grams: Double) -> NutritionValues {
        let factor = (servingGrams ?? 100) > 0
            ? grams / (servingGrams ?? 100)
            : 1.0
        return NutritionValues(
            calories: caloriesPerServing * factor,
            protein: proteinG * factor,
            carbs: carbsG * factor,
            fat: fatG * factor,
            fiber: fiberG * factor,
            sugar: sugarG * factor,
            sodium: sodiumMg * factor
        )
    }

    // Per-100g values for edit recalculation
    var per100g: NutritionValues {
        scaled(to: 100)
    }

    // Initialize from a raw SQLite3 row pointer
    init(from stmt: OpaquePointer) {
        id          = Int(sqlite3_column_int(stmt, 0))
        fdcId       = sqlite3_column_type(stmt, 1) != SQLITE_NULL
                        ? Int(sqlite3_column_int(stmt, 1)) : nil
        name        = String(cString: sqlite3_column_text(stmt, 2))
        brand       = sqlite3_column_type(stmt, 3) != SQLITE_NULL
                        ? String(cString: sqlite3_column_text(stmt, 3)) : nil
        source      = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                        ? String(cString: sqlite3_column_text(stmt, 4)) : nil
        servingGrams = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                        ? sqlite3_column_double(stmt, 5) : nil
        servingDesc = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                        ? String(cString: sqlite3_column_text(stmt, 6)) : nil
        caloriesPerServing = sqlite3_column_double(stmt, 7)
        proteinG    = sqlite3_column_double(stmt, 8)
        carbsG      = sqlite3_column_double(stmt, 9)
        fatG        = sqlite3_column_double(stmt, 10)
        fiberG      = sqlite3_column_double(stmt, 11)
        sugarG      = sqlite3_column_double(stmt, 12)
        sodiumMg    = sqlite3_column_double(stmt, 13)
        barcode     = sqlite3_column_type(stmt, 14) != SQLITE_NULL
                        ? String(cString: sqlite3_column_text(stmt, 14)) : nil
    }
}

struct NutritionValues {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var sugar: Double
    var sodium: Double
}

// MARK: - LLM Response Models

struct FoodLogResponse: Codable {
    let action: String
    let reasoning: String? // LLM thought process
    // tool requests
    let queries: [SearchQuery]?
    let dates: [String]?
    let items: [FoodLogItem]?
    let weightLbs: Double?
    let note: String?
    let foodName: String?
    let foodNames: [String]?
    let meal: String?
    let newPortionGrams: Double?
    let newPortionDescription: String?
    let goalCalories: Double?
    let goalProtein: Double?
    let goalCarbs: Double?
    let goalFat: Double?
    let goalFiber: Double?
    let question: String?
    let text: String?
    let templateName: String?
    let status: String?
    let entryId: String?

    enum CodingKeys: String, CodingKey {
        case action, reasoning, queries, dates, items, note, text, meal, question, status
        case foodName              = "food_name"
        case foodNames             = "food_names"
        case weightLbs             = "weight_lbs"
        case newPortionGrams       = "new_portion_grams"
        case newPortionDescription = "new_portion_description"
        case goalCalories          = "goal_calories"
        case goalProtein           = "goal_protein"
        case goalCarbs             = "goal_carbs"
        case goalFat               = "goal_fat"
        case goalFiber             = "goal_fiber"
        case templateName          = "template_name"
        case entryId               = "entry_id"
    }

    init(
        action: String,
        reasoning: String? = nil,
        queries: [SearchQuery]? = nil,
        dates: [String]? = nil,
        items: [FoodLogItem]? = nil,
        weightLbs: Double? = nil,
        note: String? = nil,
        foodName: String? = nil,
        foodNames: [String]? = nil,
        meal: String? = nil,
        newPortionGrams: Double? = nil,
        newPortionDescription: String? = nil,
        goalCalories: Double? = nil,
        goalProtein: Double? = nil,
        goalCarbs: Double? = nil,
        goalFat: Double? = nil,
        goalFiber: Double? = nil,
        question: String? = nil,
        text: String? = nil,
        templateName: String? = nil,
        status: String? = nil,
        entryId: String? = nil
    ) {
        self.action = action
        self.reasoning = reasoning
        self.queries = queries
        self.dates = dates
        self.items = items
        self.weightLbs = weightLbs
        self.note = note
        self.foodName = foodName
        self.foodNames = foodNames
        self.meal = meal
        self.newPortionGrams = newPortionGrams
        self.newPortionDescription = newPortionDescription
        self.goalCalories = goalCalories
        self.goalProtein = goalProtein
        self.goalCarbs = goalCarbs
        self.goalFat = goalFat
        self.goalFiber = goalFiber
        self.question = question
        self.text = text
        self.templateName = templateName
        self.status = status
        self.entryId = entryId
    }
}

struct SearchQuery: Codable {
    let q: String
    let description: String
    let meal: String?
}

struct FoodLogItem: Codable {
    let searchQuery: String?
    let candidateId: String?
    let fdcId: Int?
    let foodName: String?
    let portionDescription: String
    let estimatedGrams: Double?
    let servings: Double?
    let meal: String?

    enum CodingKeys: String, CodingKey {
        case searchQuery        = "search_query"
        case candidateId        = "candidate_id"
        case fdcId              = "fdc_id"
        case portionDescription = "portion_description"
        case foodName           = "food_name"
        case estimatedGrams     = "estimated_grams"
        case servings, meal
    }

    init(
        searchQuery: String? = nil,
        candidateId: String? = nil,
        fdcId: Int? = nil,
        foodName: String? = nil,
        portionDescription: String = "1 serving",
        estimatedGrams: Double? = nil,
        servings: Double? = nil,
        meal: String? = nil
    ) {
        self.searchQuery = searchQuery
        self.candidateId = candidateId
        self.fdcId = fdcId
        self.foodName = foodName
        self.portionDescription = portionDescription
        self.estimatedGrams = estimatedGrams
        self.servings = servings
        self.meal = meal
    }

    /// Custom decoder: LLMs sometimes emit fdc_id as a JSON string ("167906")
    /// instead of an integer (167906). Also handles food_name fallback.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchQuery        = try c.decodeIfPresent(String.self,  forKey: .searchQuery)
        candidateId        = try c.decodeIfPresent(String.self,  forKey: .candidateId)
        estimatedGrams     = try c.decodeIfPresent(Double.self,  forKey: .estimatedGrams)
        servings           = try c.decodeIfPresent(Double.self,  forKey: .servings)
        meal               = try c.decodeIfPresent(String.self,  forKey: .meal)
        foodName           = try c.decodeIfPresent(String.self,  forKey: .foodName)

        if let desc = try? c.decode(String.self, forKey: .portionDescription) {
            portionDescription = desc
        } else if let fallback = foodName {
            portionDescription = fallback
        } else {
            portionDescription = "1 serving"
        }

        if let intVal = try? c.decodeIfPresent(Int.self, forKey: .fdcId) {
            fdcId = intVal
        } else if let strVal = try? c.decodeIfPresent(String.self, forKey: .fdcId),
                  let parsed = Int(strVal) {
            fdcId = parsed
        } else {
            fdcId = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(searchQuery,        forKey: .searchQuery)
        try c.encodeIfPresent(candidateId,        forKey: .candidateId)
        try c.encodeIfPresent(fdcId,              forKey: .fdcId)
        try c.encodeIfPresent(foodName,           forKey: .foodName)
        try c.encode(portionDescription,          forKey: .portionDescription)
        try c.encodeIfPresent(estimatedGrams,     forKey: .estimatedGrams)
        try c.encodeIfPresent(servings,           forKey: .servings)
        try c.encodeIfPresent(meal,               forKey: .meal)
    }
}
