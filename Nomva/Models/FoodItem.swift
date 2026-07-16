import SQLite3
import Foundation

private func sqliteOptionalDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
    sqlite3_column_type(stmt, index) != SQLITE_NULL
        ? sqlite3_column_double(stmt, index)
        : nil
}

enum FoodPortionBasis: String, Codable, Hashable {
    case grams
    case fixedServing = "fixed_serving"
}

enum FoodServingSource: String, Codable, Hashable {
    case explicitServing = "explicit_serving"
    case parsedServing = "parsed_serving"
    case fallbackRaw = "fallback_raw"
}

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
    let saturatedFatG: Double?
    let transFatG: Double?
    let cholesterolMg: Double?
    let addedSugarG: Double?
    let vitaminDMcg: Double?
    let calciumMg: Double?
    let ironMg: Double?
    let potassiumMg: Double?
    let vitaminAMcgRAE: Double?
    let vitaminCMg: Double?
    let vitaminB12Mcg: Double?
    let folateMcgDFE: Double?
    let magnesiumMg: Double?
    let zincMg: Double?
    let barcode: String?
    let portionBasis: FoodPortionBasis
    let servingSource: FoodServingSource?

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
        saturatedFatG: Double? = nil,
        transFatG: Double? = nil,
        cholesterolMg: Double? = nil,
        addedSugarG: Double? = nil,
        vitaminDMcg: Double? = nil,
        calciumMg: Double? = nil,
        ironMg: Double? = nil,
        potassiumMg: Double? = nil,
        vitaminAMcgRAE: Double? = nil,
        vitaminCMg: Double? = nil,
        vitaminB12Mcg: Double? = nil,
        folateMcgDFE: Double? = nil,
        magnesiumMg: Double? = nil,
        zincMg: Double? = nil,
        barcode: String? = nil,
        portionBasis: FoodPortionBasis = .grams,
        servingSource: FoodServingSource? = nil
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
        self.barcode = barcode
        self.portionBasis = portionBasis
        self.servingSource = servingSource
    }

    // Convenience: nutrition scaled to a custom gram amount
    func scaled(to grams: Double) -> NutritionValues {
        guard canScaleByGrams else {
            return nutritionForServings(1)
        }
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
            sodium: sodiumMg * factor,
            saturatedFat: saturatedFatG.map { $0 * factor },
            transFat: transFatG.map { $0 * factor },
            cholesterol: cholesterolMg.map { $0 * factor },
            addedSugar: addedSugarG.map { $0 * factor },
            vitaminD: vitaminDMcg.map { $0 * factor },
            calcium: calciumMg.map { $0 * factor },
            iron: ironMg.map { $0 * factor },
            potassium: potassiumMg.map { $0 * factor },
            vitaminA: vitaminAMcgRAE.map { $0 * factor },
            vitaminC: vitaminCMg.map { $0 * factor },
            vitaminB12: vitaminB12Mcg.map { $0 * factor },
            folate: folateMcgDFE.map { $0 * factor },
            magnesium: magnesiumMg.map { $0 * factor },
            zinc: zincMg.map { $0 * factor }
        )
    }

    func nutritionForServings(_ servings: Double) -> NutritionValues {
        let factor = max(servings, 0)
        return NutritionValues(
            calories: caloriesPerServing * factor,
            protein: proteinG * factor,
            carbs: carbsG * factor,
            fat: fatG * factor,
            fiber: fiberG * factor,
            sugar: sugarG * factor,
            sodium: sodiumMg * factor,
            saturatedFat: saturatedFatG.map { $0 * factor },
            transFat: transFatG.map { $0 * factor },
            cholesterol: cholesterolMg.map { $0 * factor },
            addedSugar: addedSugarG.map { $0 * factor },
            vitaminD: vitaminDMcg.map { $0 * factor },
            calcium: calciumMg.map { $0 * factor },
            iron: ironMg.map { $0 * factor },
            potassium: potassiumMg.map { $0 * factor },
            vitaminA: vitaminAMcgRAE.map { $0 * factor },
            vitaminC: vitaminCMg.map { $0 * factor },
            vitaminB12: vitaminB12Mcg.map { $0 * factor },
            folate: folateMcgDFE.map { $0 * factor },
            magnesium: magnesiumMg.map { $0 * factor },
            zinc: zincMg.map { $0 * factor }
        )
    }

    var canScaleByGrams: Bool {
        portionBasis == .grams && (servingGrams ?? 0) > 0
    }

    // Per-100g values for edit recalculation
    var per100g: NutritionValues {
        canScaleByGrams ? scaled(to: 100) : NutritionValues.zero
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
        saturatedFatG = sqliteOptionalDouble(stmt, 14)
        transFatG = sqliteOptionalDouble(stmt, 15)
        cholesterolMg = sqliteOptionalDouble(stmt, 16)
        addedSugarG = sqliteOptionalDouble(stmt, 17)
        vitaminDMcg = sqliteOptionalDouble(stmt, 18)
        calciumMg = sqliteOptionalDouble(stmt, 19)
        ironMg = sqliteOptionalDouble(stmt, 20)
        potassiumMg = sqliteOptionalDouble(stmt, 21)
        vitaminAMcgRAE = sqliteOptionalDouble(stmt, 22)
        vitaminCMg = sqliteOptionalDouble(stmt, 23)
        vitaminB12Mcg = sqliteOptionalDouble(stmt, 24)
        folateMcgDFE = sqliteOptionalDouble(stmt, 25)
        magnesiumMg = sqliteOptionalDouble(stmt, 26)
        zincMg = sqliteOptionalDouble(stmt, 27)
        barcode     = sqlite3_column_type(stmt, 28) != SQLITE_NULL
                        ? String(cString: sqlite3_column_text(stmt, 28)) : nil
        if sqlite3_column_type(stmt, 29) != SQLITE_NULL,
           let raw = sqlite3_column_text(stmt, 29).map({ String(cString: $0) }),
           let parsed = FoodPortionBasis(rawValue: raw) {
            portionBasis = parsed
        } else {
            portionBasis = .grams
        }
        if sqlite3_column_type(stmt, 30) != SQLITE_NULL,
           let raw = sqlite3_column_text(stmt, 30).map({ String(cString: $0) }) {
            servingSource = FoodServingSource(rawValue: raw)
        } else {
            servingSource = nil
        }
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
    var saturatedFat: Double? = nil
    var transFat: Double? = nil
    var cholesterol: Double? = nil
    var addedSugar: Double? = nil
    var vitaminD: Double? = nil
    var calcium: Double? = nil
    var iron: Double? = nil
    var potassium: Double? = nil
    var vitaminA: Double? = nil
    var vitaminC: Double? = nil
    var vitaminB12: Double? = nil
    var folate: Double? = nil
    var magnesium: Double? = nil
    var zinc: Double? = nil

    static let zero = NutritionValues(
        calories: 0,
        protein: 0,
        carbs: 0,
        fat: 0,
        fiber: 0,
        sugar: 0,
        sodium: 0
    )
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
