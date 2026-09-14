import Foundation

/// A saved portion is a valid nutrition basis even when its weight is unknown.
/// Capture it before editing so repeated previews never compound the scaling.
struct FoodPortionSnapshot {
    let grams: Double
    let servings: Double
    let nutrition: NutritionValues

    init(_ entry: FoodEntry) {
        grams = entry.portionGrams
        servings = entry.servings
        nutrition = NutritionValues(
            calories: entry.calories, protein: entry.proteinG, carbs: entry.carbsG,
            fat: entry.fatG, fiber: entry.fiberG, sugar: entry.sugarG, sodium: entry.sodiumMg,
            saturatedFat: entry.saturatedFatG, transFat: entry.transFatG,
            cholesterol: entry.cholesterolMg, addedSugar: entry.addedSugarG,
            vitaminD: entry.vitaminDMcg, calcium: entry.calciumMg, iron: entry.ironMg,
            potassium: entry.potassiumMg, vitaminA: entry.vitaminAMcgRAE,
            vitaminC: entry.vitaminCMg, vitaminB12: entry.vitaminB12Mcg,
            folate: entry.folateMcgDFE, magnesium: entry.magnesiumMg, zinc: entry.zincMg
        )
    }

    var hasKnownWeight: Bool { grams.isFinite && grams > 0 }
    var gramsPerServing: Double { hasKnownWeight && servings > 0 ? grams / servings : 0 }

    func scaledNutrition(grams newGrams: Double, servings newServings: Double) -> NutritionValues {
        let factor = hasKnownWeight ? newGrams / grams : newServings / max(servings, 0.05)
        return nutrition.scaled(by: factor)
    }

    func apply(to entry: FoodEntry, scale: Double, servings: Double, unit: String, description: String) {
        let values = nutrition.scaled(by: scale)
        entry.portionGrams = hasKnownWeight ? grams * scale : 0
        entry.servings = servings
        entry.servingUnit = unit
        entry.portionDescription = description
        entry.calories = values.calories
        entry.proteinG = values.protein
        entry.carbsG = values.carbs
        entry.fatG = values.fat
        entry.fiberG = values.fiber
        entry.sugarG = values.sugar
        entry.sodiumMg = values.sodium
        entry.saturatedFatG = values.saturatedFat
        entry.transFatG = values.transFat
        entry.cholesterolMg = values.cholesterol
        entry.addedSugarG = values.addedSugar
        entry.vitaminDMcg = values.vitaminD
        entry.calciumMg = values.calcium
        entry.ironMg = values.iron
        entry.potassiumMg = values.potassium
        entry.vitaminAMcgRAE = values.vitaminA
        entry.vitaminCMg = values.vitaminC
        entry.vitaminB12Mcg = values.vitaminB12
        entry.folateMcgDFE = values.folate
        entry.magnesiumMg = values.magnesium
        entry.zincMg = values.zinc
    }
}

extension NutritionValues {
    func scaled(by factor: Double) -> NutritionValues {
        NutritionValues(
            calories: calories * factor, protein: protein * factor, carbs: carbs * factor,
            fat: fat * factor, fiber: fiber * factor, sugar: sugar * factor, sodium: sodium * factor,
            saturatedFat: saturatedFat.map { $0 * factor }, transFat: transFat.map { $0 * factor },
            cholesterol: cholesterol.map { $0 * factor }, addedSugar: addedSugar.map { $0 * factor },
            vitaminD: vitaminD.map { $0 * factor }, calcium: calcium.map { $0 * factor },
            iron: iron.map { $0 * factor }, potassium: potassium.map { $0 * factor },
            vitaminA: vitaminA.map { $0 * factor }, vitaminC: vitaminC.map { $0 * factor },
            vitaminB12: vitaminB12.map { $0 * factor }, folate: folate.map { $0 * factor },
            magnesium: magnesium.map { $0 * factor }, zinc: zinc.map { $0 * factor }
        )
    }
}

enum FoodCorrectionIntent {
    static func isExplicit(_ message: String) -> Bool {
        message.range(of: #"(?i)\b(?:not\s+(?:just\s+|only\s+)?(?:\d|half\b|one\b|two\b)|instead\s+of|rather\s+than|I\s+meant|actually\s+(?:I\s+)?(?:had|ate|drank|it|that)|(?:that|it)\s+was\s+(?:only|actually))"#,
                      options: .regularExpression) != nil
    }

    static func namedTarget(in message: String, entries: [FoodEntry]) -> FoodEntry? {
        let ignored = Set("i a an the my that this it was is were to for from with without actually make change edit fix correct update had ate drank not just only whole entire full of serving servings cup cups oz ounce ounces gram grams g cal calories bottle bottles can cans packet packets fl ml one two three half".split(separator: " ").map(String.init))
        func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: .alphanumerics.inverted)
                .filter { !$0.isEmpty && !ignored.contains($0) && Double($0) == nil })
        }
        let words = tokens(message)
        let matches = entries.filter { !words.intersection(tokens("\($0.brand ?? "") \($0.name)")).isEmpty }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Converts compatible portion units without asking a model to do arithmetic.
enum FoodPortionMath {
    struct Measure {
        let amount: Double
        let unit: String
        let dimension: String
        let factor: Double
        var baseAmount: Double { amount * factor }
        var description: String { "\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(unit)" }
    }

    private static let number = #"(?:\d+(?:\.\d+)?\s+\d+\s*/\s*\d+|\d+\s*/\s*\d+|\d+(?:\.\d+)?|half|quarter|one|two|three|four|a|an)"#
    private static let physicalUnit = #"(?:fl\.?\s*oz\.?|fluid\s+ounces?|millilit(?:er|re)s?|ml|lit(?:er|re)s?|l|cups?|tablespoons?|tbsp|teaspoons?|tsp|kilograms?|kg|grams?|g|ounces?|oz|pounds?|lbs?)"#

    private static func amount(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(text) { return value }
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "half": 0.5, "quarter": 0.25]
        if let value = words[text] { return value }
        let parts = text.components(separatedBy: "/")
        guard parts.count == 2, let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)), denominator > 0 else { return nil }
        let left = parts[0].split(separator: " ").compactMap { Double($0) }
        guard let numerator = left.last else { return nil }
        return (left.count > 1 ? left[0] : 0) + numerator / denominator
    }

    static func measure(in text: String, beverage: Bool) -> Measure? {
        let text = text.lowercased().replacingOccurrences(of: "½", with: " 1/2").replacingOccurrences(of: "¼", with: " 1/4").replacingOccurrences(of: "¾", with: " 3/4")
        let pattern = "\\b(\(number))\\s*(?:-\\s*)?(\(physicalUnit))(?=$|\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = amount(String(text[amountRange])), value > 0 else { return nil }
        let raw = String(text[unitRange]).replacingOccurrences(of: ".", with: "")
        let unit: String, dimension: String, factor: Double
        switch raw {
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres": (unit, dimension, factor) = ("ml", "volume", 1)
        case "l", "liter", "liters", "litre", "litres": (unit, dimension, factor) = ("l", "volume", 1000)
        case "cup", "cups": (unit, dimension, factor) = ("cup", "volume", 236.5882365)
        case "tablespoon", "tablespoons", "tbsp": (unit, dimension, factor) = ("tbsp", "volume", 14.78676478125)
        case "teaspoon", "teaspoons", "tsp": (unit, dimension, factor) = ("tsp", "volume", 4.92892159375)
        case "kg", "kilogram", "kilograms": (unit, dimension, factor) = ("kg", "mass", 1000)
        case "g", "gram", "grams": (unit, dimension, factor) = ("g", "mass", 1)
        case "lb", "lbs", "pound", "pounds": (unit, dimension, factor) = ("lb", "mass", 453.59237)
        default:
            let isVolume = beverage || raw.hasPrefix("fl")
            (unit, dimension, factor) = isVolume ? ("fl oz", "volume", 29.5735295625) : ("oz", "mass", 28.349523125)
        }
        return Measure(amount: value, unit: unit, dimension: dimension, factor: factor)
    }

    static func isBeverage(_ entry: FoodEntry) -> Bool {
        "\(entry.name) \(entry.portionDescription) \(entry.servingUnit)".range(
            of: #"(?i)\b(drink|juice|soda|cola|coffee|tea|milk|water|gatorade|powerade|celsius|beer|wine|shake|fl\s*oz|ml)\b"#,
            options: .regularExpression) != nil
    }

    static func requestedMeasure(in message: String, beverage: Bool) -> Measure? {
        let contrast = message.range(of: #"(?i)\b(?:not|instead of|rather than)\s+"#, options: .regularExpression)
        return measure(in: String(message[..<(contrast?.lowerBound ?? message.endIndex)]), beverage: beverage)
    }

    static func wholeContainer(for entry: FoodEntry, message: String) -> EditResolution? {
        if let contrast = message.range(of: #"(?i)\b(?:not|instead of|rather than)\s+"#, options: .regularExpression),
           measure(in: String(message[contrast.upperBound...]), beverage: isBeverage(entry)) == nil {
            // An identity correction such as "Gatorade, not Coke" needs the food resolver.
            return nil
        }
        guard let container = ["bottle", "can", "packet", "package"].first(where: {
            message.range(of: "(?i)\\b(?:whole|entire|full)\\s+\($0)\\b", options: .regularExpression) != nil
        }) else { return nil }
        if let size = requestedMeasure(in: message, beverage: isBeverage(entry)) {
            return EditResolution(servings: 1, portionDescription: "1 \(container) (\(size.description))",
                servingUnit: container, confident: true, hasExplicitPortion: true,
                clarificationQuestion: nil, replacementSearchQuery: nil)
        }
        // Only use this entry's own portion/product size, never a neighboring drink's size.
        let text = "\(entry.name) \(entry.portionDescription)".lowercased()
        let patterns = [
            "\\b(\(number)\\s*\(physicalUnit))\\s*\(container)\\b",
            "\\b\(container)\\s*\\((\(number)\\s*\(physicalUnit))\\)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let size = measure(in: String(text[range]), beverage: isBeverage(entry)) else { continue }
            return EditResolution(servings: 1, portionDescription: "1 \(container) (\(size.description))",
                servingUnit: container, confident: true, hasExplicitPortion: true,
                clarificationQuestion: nil, replacementSearchQuery: nil)
        }
        return nil
    }

    static func resizedDescription(for entry: FoodEntry, scale: Double, description: String) -> String {
        guard measure(in: description, beverage: isBeverage(entry)) == nil,
              let size = measure(in: entry.portionDescription, beverage: isBeverage(entry))
                ?? measure(in: entry.name, beverage: isBeverage(entry)) else { return description }
        let resized = Measure(amount: size.amount * scale, unit: size.unit, dimension: size.dimension, factor: size.factor)
        return "\(description) (\(resized.description))"
    }

    static func scale(for entry: FoodEntry, description: String, servings: Double, unit: String) -> Double? {
        let beverage = isBeverage(entry)
        // Some published rows encode the nutrition serving in the product name:
        // "12 fl oz (28 oz bottle)". The first measure is the logged nutrition basis.
        let current = measure(in: entry.portionDescription, beverage: beverage)
            ?? measure(in: entry.name, beverage: beverage)
        let requested = measure(in: description, beverage: beverage)
        if let current, let requested, current.dimension == requested.dimension {
            return requested.baseAmount / current.baseAmount
        }
        // A different physical unit needs a conversion or clarification, never a count ratio.
        guard requested == nil else { return nil }
        let normalize: (String) -> String = { $0.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"s$"#, with: "", options: .regularExpression) }
        guard normalize(entry.servingUnit) == normalize(unit), entry.servings > 0 else { return nil }
        return servings / entry.servings
    }
}
