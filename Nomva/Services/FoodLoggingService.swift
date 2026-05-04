import Foundation

private enum CandidateSource: String {
    case database, custom, recent
}

private struct SearchCandidate {
    let candidateId: String
    let source: CandidateSource
    let databaseSource: String?
    let fdcId: Int?
    let customFoodId: UUID?
    let recentEntryId: UUID?
    let name: String
    let brand: String?
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
    let per100gValues: NutritionValues
    var score: Int = 0

    func scaled(to grams: Double) -> NutritionValues {
        guard canScaleByGrams else {
            return nutritionForServings(1)
        }
        let base = (servingGrams ?? 100) > 0 ? (servingGrams ?? 100) : 100
        let factor = grams / base
        return NutritionValues(
            calories: caloriesPerServing * factor, protein: proteinG * factor, carbs: carbsG * factor,
            fat: fatG * factor, fiber: fiberG * factor, sugar: sugarG * factor, sodium: sodiumMg * factor,
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
            calories: caloriesPerServing * factor, protein: proteinG * factor, carbs: carbsG * factor,
            fat: fatG * factor, fiber: fiberG * factor, sugar: sugarG * factor, sodium: sodiumMg * factor,
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
    var per100g: NutritionValues { per100gValues }
}

private struct CandidateResolution {
    let candidate: SearchCandidate
    let servingsInfo: ServingsInfo
}

/// One executed round of the find-food agent loop on the iOS side: the
/// query the LLM asked us to run plus the candidates that came back from
/// the on-device DB search.
private struct AgentSearchRound {
    let query: String
    let candidates: [SearchCandidate]
}

/// Result of asking the LLM for the next agent step. Wraps the throwing
/// call so the caller can stay flat.
private enum AgentStepOutcome {
    case step(FindFoodStep)
    case unsupported
    case failed
}

private let fillerWords: Set<String> = [
    "a", "an", "the", "for", "at", "to", "of", "and", "with", "i", "had",
    "ate", "drank", "this", "that", "it", "was", "just", "my", "me", "please",
    "no", "yes", "item", "items", "dude", "actually", "instead", "meant", "wasn", "t"
]

private let mealWords: Set<String> = ["breakfast", "lunch", "dinner", "snack"]

private let countWords: Set<String> = [
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "couple", "pair", "double"
]

private let unitWords: Set<String> = [
    "cup", "cups", "bowl", "bowls", "slice", "slices", "piece", "pieces", "serving", "servings",
    "oz", "ounce", "ounces", "gram", "grams", "g", "lb", "lbs", "small", "medium", "large",
    "tablespoon", "tablespoons", "tbsp", "teaspoon", "teaspoons", "tsp", "bottle", "bottles", "can", "cans"
]

private let preparationWords: Set<String> = [
    "raw", "cooked", "fried", "baked", "grilled", "roasted", "plain", "instant", "dehydrated",
    "dried", "powder", "chips", "juice", "smoothie", "drink", "mix", "bar", "candy", "pudding",
    "bread", "muffin", "flavored", "chocolate", "yogurt", "yoghurt"
]

private let suspiciousFormWords: [String] = [
    "dehydrated", "dried", "powder", "chips", "juice", "drink", "smoothie", "mix", "bar", "candy",
    "pudding", "bread", "muffin", "pepper", "syrup", "sauce", "mustard", "gelatin", "dessert",
    "cookie", "oatmeal", "cereal", "granola", "waffle", "waffles", "cream", "flavored", "shake",
    "yogurt", "yoghurt", "protein"
]

private let nutritionModifierWords: Set<String> = [
    "low", "light", "lite", "reduced", "lean", "skinless", "fat", "free", "nonfat", "non", "diet"
]

private let wholeFoodNeutralWords: Set<String> = ["raw", "plain", "fresh"]

private let baseDescriptorWords: Set<String> = [
    "pork", "beef", "whole", "cured", "uncured", "prepared", "unprepared", "cooked", "baked", "fried", "raw", "plain", "fresh"
]

private let variantQualifierWords: Set<String> = [
    "meatless", "vegetarian", "vegan", "white", "yolk", "duck", "goose", "quail", "turkey", "canadian",
    "bit", "wrapped", "ranch", "maple", "onion", "jam", "sauce",
    "dressing", "pizza", "bean", "cheddar", "smoky", "club",
    "original", "center", "cut", "style", "grease", "salad", "cobb", "kids", "kid", "meal", "medium", "large", "small"
]

@MainActor
final class FoodLoggingService {
    static let shared = FoodLoggingService()
    private let db = DatabaseManager.shared

    /// Returns the likely restaurant or brand phrase mentioned in a query
    /// by taking all identity tokens except the last one (the food item).
    /// For example, "chick-fil-a nuggets" → "chick fil a".
    private func potentialBrandPhrase(in query: String) -> String? {
        let tokens = identityTokens(in: query)
        guard tokens.count > 1 else { return nil }
        let phraseTokens = tokens.dropLast()
        let phrase = phraseTokens.joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    enum ChatAction {
        case logFood([FoodEntry])
        case replaceEntry(deleteName: String, newEntries: [FoodEntry])
        case editEntry(foodName: String, newGrams: Double, newDescription: String, newServings: Double, newServingUnit: String)
        case deleteEntry(foodNames: [String])
        case deleteMeal(meal: String)
        case deleteAllWeights
        case log_weight(WeightEntry)
        case updateWeight(id: String, weightLbs: Double)
        case deleteWeight(date: String)
        case logWater(oz: Double)
        case deleteWater
        case setWaterTotal(oz: Double)
        case setGoal(calories: Double?, protein: Double?, carbs: Double?, fat: Double?, fiber: Double?)
        case askClarification(String)
        case reply(String)
    }

    struct LoggingResult {
        let action: ChatAction
        var reply: String
        var sessionState: AgentTaskState? = nil
        var clearSession: Bool = true
        var trace: AgentTraceDraft? = nil
        var evidenceDrafts: [ResolvedFoodEvidenceDraft] = []
    }

    struct ResolvedFoodEvidenceDraft {
        let sourceType: String
        let fdcId: Int?
        let matchedName: String
        let matchedBrand: String?
        let searchTerms: String
        let candidateSummary: String
        let resolutionConfidence: Double
        let wasClarified: Bool
    }

    struct AgentTraceDraft {
        let userMessage: String
        let detectedIntent: String
        let providerType: String
        let usedFallback: Bool
        let rawModelAction: String?
        let routedAction: String?
        let finalAction: String
        let validationSummary: String
        let searchSummary: String?
        let candidateSummary: String?
        let rawModelResponse: String?
        var finalReply: String?
    }

    @MainActor
    private func activeProvider() -> any LLMProvider {
        LLMProviderFactory.active()
    }

    // MARK: - Focused Pipeline
    //
    // Each step makes ONE small call to GPT-4o-mini via the Nomva Cloud API.
    // No giant system prompts, no JSON schema guessing — just tiny focused questions.

    func process(
        userMessage: String,
        recentMessages: [(role: String, content: String)],
        goals: DailyGoal,
        targetDate: Date,
        targetEntries: [FoodEntry],
        recentEntries: [FoodEntry],
        customFoods: [CustomFood] = [],
        weightEntries: [WeightEntry] = [],
        waterEntries: [WaterEntry] = [],
        mealTemplates: [MealTemplate] = [],
        sessionState: AgentTaskState? = nil
    ) async -> LoggingResult {

        // PRODUCTION GUARD
        guard SubscriptionManager.shared.canUseAI else {
            return .reply("You've reached your limit. Upgrade to Nomva Pro in Settings to keep chatting!")
        }

        let provider = activeProvider()
        let dayEntries = targetEntries
        let dayLabel = Self.dayContextLabel(for: targetDate)

        if sessionState?.intent == UserIntentKind.editFood.rawValue,
           sessionState?.status == "awaiting_clarification",
           sessionState?.unresolvedSlots.contains("portion") == true,
           sessionState?.correctionTargetName != nil {
            return await handleEditFood(
                userMessage: userMessage,
                provider: provider,
                dayEntries: dayEntries,
                dayLabel: dayLabel,
                recentEntries: recentEntries,
                customFoods: customFoods,
                recentMessages: recentMessages,
                sessionState: sessionState
            )
        }

        // Step 1: Classify intent
        let intent: UserIntentKind
        do {
            intent = try await provider.classifyIntent(
                userMessage: userMessage,
                recentMessages: recentMessages
            )
        } catch {
            return handleProviderError(error)
        }

        switch intent {
        case .logFood:
            return await handleLogFood(
                userMessage: userMessage,
                provider: provider,
                recentEntries: recentEntries,
                customFoods: customFoods
            )

        case .deleteFood:
            return await handleDeleteFood(
                userMessage: userMessage,
                provider: provider,
                dayEntries: dayEntries,
                dayLabel: dayLabel,
                recentMessages: recentMessages
            )

        case .editFood:
            return await handleEditFood(
                userMessage: userMessage,
                provider: provider,
                dayEntries: dayEntries,
                dayLabel: dayLabel,
                recentEntries: recentEntries,
                customFoods: customFoods,
                recentMessages: recentMessages,
                sessionState: sessionState
            )

        case .queryData:
            return await handleQuery(
                userMessage: userMessage,
                provider: provider,
                goals: goals,
                dayEntries: dayEntries,
                dayLabel: dayLabel,
                recentEntries: recentEntries,
                weightEntries: weightEntries,
                waterEntries: waterEntries,
                recentMessages: recentMessages
            )

        case .logWeight:
            return await handleLogWeight(
                userMessage: userMessage,
                provider: provider,
                weightEntries: weightEntries,
                targetDate: targetDate
            )

        case .logWater:
            return await handleLogWater(
                userMessage: userMessage,
                provider: provider,
                waterEntries: waterEntries,
                targetDate: targetDate
            )

        case .setGoal:
            return await handleSetGoal(userMessage: userMessage, provider: provider, recentMessages: recentMessages)

        case .reply:
            return await handleGeneralReply(
                userMessage: userMessage,
                provider: provider,
                goals: goals,
                dayEntries: dayEntries,
                dayLabel: dayLabel,
                recentEntries: recentEntries,
                weightEntries: weightEntries,
                waterEntries: waterEntries,
                recentMessages: recentMessages
            )
        }
    }

    // MARK: - Log Food (focused pipeline)

    private func handleLogFood(
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood]
    ) async -> LoggingResult {

        // Step 2: Split into individual food mentions
        let foodMentions: [String]
        do {
            foodMentions = try await provider.splitFoods(userMessage: userMessage)
        } catch {
            return handleProviderError(error)
        }

        // Step 3: Extract meal
        let meal: String
        do {
            meal = try await provider.extractMeal(userMessage: userMessage) ?? "snack"
        } catch {
            meal = "snack"
        }

        var entries: [FoodEntry] = []
        var confirmLines: [String] = []

        for mention in foodMentions {
            let initialServings = await initialServingsInfo(
                for: mention,
                userMessage: userMessage,
                provider: provider
            )

            guard let resolution = await resolveLoggedCandidate(
                mention: mention,
                userMessage: userMessage,
                provider: provider,
                recentEntries: recentEntries,
                customFoods: customFoods,
                initialServingsInfo: initialServings
            ) else {
                confirmLines.append("I couldn't confidently match \"\(mention)\"")
                continue
            }

            guard let builtEntry = await loggedEntry(
                for: resolution.candidate,
                mention: mention,
                userMessage: userMessage,
                meal: meal,
                servingsInfo: resolution.servingsInfo,
                provider: provider,
                recentEntries: recentEntries,
                customFoods: customFoods
            ) else {
                confirmLines.append("I couldn't confidently size \"\(resolution.candidate.name)\". Could you be a bit more specific?")
                continue
            }

            // Deduplication: only skip if we already added this food in THIS message
            if entries.contains(where: { $0.name == builtEntry.name && $0.meal == meal }) {
                continue
            }

            entries.append(builtEntry)
            confirmLines.append("\(builtEntry.name) (\(builtEntry.portionDescription)) — \(Int(builtEntry.calories)) cal")
        }

        if entries.isEmpty {
            return .reply("I couldn't find any matching foods to log. Could you try being more specific?")
        }
        return .init(action: .logFood(entries), reply: "✓ " + confirmLines.joined(separator: "\n✓ "))
    }

    // MARK: - Edit Food

    private func handleEditFood(
        userMessage: String,
        provider: any LLMProvider,
        dayEntries: [FoodEntry],
        dayLabel: String,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        recentMessages: [(role: String, content: String)],
        sessionState: AgentTaskState?
    ) async -> LoggingResult {
        guard !dayEntries.isEmpty else {
            return .reply("Your log for \(dayLabel) is empty — nothing to edit.")
        }

        if let pinnedName = sessionState?.correctionTargetName,
           let pinnedEntry = resolveEntry(named: pinnedName, in: dayEntries) {
            return await applyEdit(
                userMessage: userMessage,
                provider: provider,
                entry: pinnedEntry,
                recentEntries: recentEntries,
                customFoods: customFoods,
                sessionState: sessionState
            )
        }

        let logSummary = dayEntries.map { "\($0.name) (\($0.portionDescription), \($0.meal))" }.joined(separator: "\n")
        let selection: EditTargetSelection
        do {
            selection = try await provider.pickEditTarget(
                userMessage: userMessage,
                logSummary: logSummary,
                recentMessages: recentMessages
            )
        } catch {
            if dayEntries.count == 1, let onlyEntry = dayEntries.first {
                return await applyEdit(
                    userMessage: userMessage,
                    provider: provider,
                    entry: onlyEntry,
                    recentEntries: recentEntries,
                    customFoods: customFoods,
                    sessionState: sessionState
                )
            }
            return clarificationResult(
                question: "Which item should I change?",
                userMessage: userMessage,
                correctionTargetName: nil
            )
        }

        if let targetName = selection.foodName,
           let entry = resolveEntry(named: targetName, in: dayEntries) {
            return await applyEdit(
                userMessage: userMessage,
                provider: provider,
                entry: entry,
                recentEntries: recentEntries,
                customFoods: customFoods,
                sessionState: sessionState
            )
        }

        if dayEntries.count == 1, let onlyEntry = dayEntries.first {
            return await applyEdit(
                userMessage: userMessage,
                provider: provider,
                entry: onlyEntry,
                recentEntries: recentEntries,
                customFoods: customFoods,
                sessionState: sessionState
            )
        }

        return clarificationResult(
            question: selection.clarificationQuestion ?? "Which item should I change?",
            userMessage: userMessage,
            correctionTargetName: nil
        )
    }

    private func applyEdit(
        userMessage: String,
        provider: any LLMProvider,
        entry: FoodEntry,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        sessionState: AgentTaskState?
    ) async -> LoggingResult {
        let editResolution: EditResolution
        do {
            editResolution = try await provider.resolveEditRequest(
                userMessage: userMessage,
                currentEntryName: entry.name,
                currentEntryBrand: entry.brand,
                currentPortionDescription: entry.portionDescription
            )
        } catch {
            return clarificationResult(
                question: "What amount should I change \(entry.name) to?",
                userMessage: userMessage,
                correctionTargetName: entry.name,
                originalUserMessage: sessionState?.originalUserMessage
            )
        }

        let replacementSearchQuery = editResolution.replacementSearchQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let effectiveResolution: EditResolution
        if !editResolution.hasExplicitPortion, replacementSearchQuery != nil {
            effectiveResolution = EditResolution(
                servings: max(0.1, entry.servings),
                portionDescription: entry.portionDescription.isEmpty ? "1 serving" : entry.portionDescription,
                servingUnit: entry.servingUnit.isEmpty ? "serving" : entry.servingUnit,
                confident: editResolution.confident,
                hasExplicitPortion: true,
                clarificationQuestion: nil,
                replacementSearchQuery: replacementSearchQuery
            )
        } else {
            effectiveResolution = editResolution
        }

        guard effectiveResolution.hasExplicitPortion else {
            return clarificationResult(
                question: effectiveResolution.clarificationQuestion ?? "What amount should I change \(entry.name) to?",
                userMessage: userMessage,
                correctionTargetName: entry.name,
                originalUserMessage: sessionState?.originalUserMessage
            )
        }

        let servingsInfo = ServingsInfo(
            servings: effectiveResolution.servings,
            portionDescription: effectiveResolution.portionDescription,
            servingUnit: resolvedServingUnit(effectiveResolution.servingUnit),
            confident: effectiveResolution.confident,
            hasExplicitPortion: effectiveResolution.hasExplicitPortion
        )

        if canEditDirectly(entry),
           replacementSearchQuery == nil {
            let newGrams = await estimateGrams(
                for: SearchCandidate(
                    candidateId: "entry_\(entry.id.uuidString)",
                    source: .recent,
                    databaseSource: entry.source,
                    fdcId: entry.fdcId,
                    customFoodId: nil,
                    recentEntryId: entry.id,
                    name: entry.name,
                    brand: entry.brand,
                    servingGrams: entry.portionGrams,
                    servingDesc: entry.portionDescription,
                    caloriesPerServing: entry.calories,
                    proteinG: entry.proteinG,
                    carbsG: entry.carbsG,
                    fatG: entry.fatG,
                    fiberG: entry.fiberG,
                    sugarG: entry.sugarG,
                    sodiumMg: entry.sodiumMg,
                    saturatedFatG: entry.saturatedFatG,
                    transFatG: entry.transFatG,
                    cholesterolMg: entry.cholesterolMg,
                    addedSugarG: entry.addedSugarG,
                    vitaminDMcg: entry.vitaminDMcg,
                    calciumMg: entry.calciumMg,
                    ironMg: entry.ironMg,
                    potassiumMg: entry.potassiumMg,
                    vitaminAMcgRAE: entry.vitaminAMcgRAE,
                    vitaminCMg: entry.vitaminCMg,
                    vitaminB12Mcg: entry.vitaminB12Mcg,
                    folateMcgDFE: entry.folateMcgDFE,
                    magnesiumMg: entry.magnesiumMg,
                    zincMg: entry.zincMg,
                    barcode: entry.barcode,
                    portionBasis: entry.portionGrams > 0 && entry.caloriesPer100g > 0 ? .grams : .fixedServing,
                    servingSource: nil,
                    per100gValues: NutritionValues(
                        calories: entry.caloriesPer100g,
                        protein: entry.proteinPer100g,
                        carbs: entry.carbsPer100g,
                        fat: entry.fatPer100g,
                        fiber: entry.fiberPer100g,
                        sugar: entry.sugarPer100g,
                        sodium: entry.sodiumPer100g,
                        saturatedFat: entry.saturatedFatPer100g,
                        transFat: entry.transFatPer100g,
                        cholesterol: entry.cholesterolPer100g,
                        addedSugar: entry.addedSugarPer100g,
                        vitaminD: entry.vitaminDPer100g,
                        calcium: entry.calciumPer100g,
                        iron: entry.ironPer100g,
                        potassium: entry.potassiumPer100g,
                        vitaminA: entry.vitaminAPer100g,
                        vitaminC: entry.vitaminCPer100g,
                        vitaminB12: entry.vitaminB12Per100g,
                        folate: entry.folatePer100g,
                        magnesium: entry.magnesiumPer100g,
                        zinc: entry.zincPer100g
                    )
                ),
                portionDescription: servingsInfo.portionDescription,
                provider: provider,
                referenceServingDescription: entry.portionDescription,
                referenceServingGrams: entry.portionGrams > 0 ? entry.portionGrams : nil
            )

            return .init(
                action: .editEntry(
                    foodName: entry.name,
                    newGrams: newGrams,
                    newDescription: servingsInfo.portionDescription,
                    newServings: servingsInfo.servings,
                    newServingUnit: servingsInfo.servingUnit
                ),
                reply: "✓ Updated \(entry.name) to \(servingsInfo.portionDescription)"
            )
        }

        let replacementQuery = replacementSearchQuery ?? entry.name
        let candidates = await searchCandidates(query: replacementQuery, recentEntries: recentEntries, customFoods: customFoods)
        guard let replacementCandidate = await chooseCandidate(
            from: candidates,
            userMessage: userMessage,
            foodMention: replacementQuery,
            provider: provider
        ) else {
            return clarificationResult(
                question: effectiveResolution.clarificationQuestion ?? "What amount should I change \(entry.name) to?",
                userMessage: userMessage,
                correctionTargetName: entry.name,
                originalUserMessage: sessionState?.originalUserMessage
            )
        }

        guard let replacementEntry = await loggedEntry(
            for: replacementCandidate,
            mention: replacementQuery,
            userMessage: userMessage,
            meal: entry.meal,
            servingsInfo: servingsInfo,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods
        ) else {
            return clarificationResult(
                question: effectiveResolution.clarificationQuestion ?? "What amount should I change \(entry.name) to?",
                userMessage: userMessage,
                correctionTargetName: entry.name,
                originalUserMessage: sessionState?.originalUserMessage
            )
        }

        return .init(
            action: .replaceEntry(deleteName: entry.name, newEntries: [replacementEntry]),
            reply: "✓ Updated \(entry.name) to \(servingsInfo.portionDescription)"
        )
    }

    private func clarificationResult(
        question: String,
        userMessage: String,
        correctionTargetName: String?,
        originalUserMessage: String? = nil
    ) -> LoggingResult {
        let state = AgentTaskState(
            taskId: UUID(),
            status: "awaiting_clarification",
            intent: UserIntentKind.editFood.rawValue,
            originalUserMessage: originalUserMessage ?? userMessage,
            latestUserMessage: userMessage,
            meal: nil,
            pendingDescriptions: [],
            unresolvedSlots: [correctionTargetName == nil ? "target" : "portion"],
            lastQuestion: question,
            correctionTargetName: correctionTargetName,
            lastToolContext: nil,
            candidateGroups: []
        )
        return .init(
            action: .askClarification(question),
            reply: question,
            sessionState: state,
            clearSession: false
        )
    }

    private func resolveEntry(named target: String, in entries: [FoodEntry]) -> FoodEntry? {
        let loweredTarget = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = entries.first(where: { $0.name.lowercased() == loweredTarget }) {
            return exact
        }
        if let brandExact = entries.first(where: {
            let fullName = "\(($0.brand ?? "").lowercased()) \($0.name.lowercased())".trimmingCharacters(in: .whitespaces)
            return fullName == loweredTarget
        }) {
            return brandExact
        }
        return entries.first(where: {
            let fullName = "\(($0.brand ?? "").lowercased()) \($0.name.lowercased())"
            return fullName.contains(loweredTarget) || loweredTarget.contains($0.name.lowercased())
        })
    }

    private func initialServingsInfo(
        for mention: String,
        userMessage: String,
        provider: any LLMProvider
    ) async -> ServingsInfo {
        do {
            return try await provider.extractServings(
                userMessage: userMessage,
                foodMention: mention,
                candidateName: mention,
                candidateServingDescription: nil
            )
        } catch {
            return ServingsInfo(
                servings: 1,
                portionDescription: "1 serving",
                servingUnit: "serving",
                confident: false,
                hasExplicitPortion: false
            )
        }
    }

    private func resolveLoggedCandidate(
        mention: String,
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        initialServingsInfo: ServingsInfo
    ) async -> CandidateResolution? {
        if let searchResolution = await highConfidenceSearchResolution(
            mention: mention,
            recentEntries: recentEntries,
            customFoods: customFoods,
            initialServingsInfo: initialServingsInfo
        ) {
            return searchResolution
        }

        // Try the server-side resolver only after the local high-confidence
        // search path. The server can inspect a read-only DB copy, but the
        // on-device DB search is the source of truth for rows the app can save.
        if let serverResolution = await serverResolveLoggedCandidate(
            mention: mention,
            userMessage: userMessage,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods,
            initialServingsInfo: initialServingsInfo
        ) {
            return serverResolution
        }

        // Next try the local agent loop: the LLM drives query construction,
        // sees candidates from each round, and picks one. If that path is
        // unavailable or malformed, fall back to the legacy chooseCandidate +
        // validate chain below.
        if let agentResolution = await agentResolveLoggedCandidate(
            mention: mention,
            userMessage: userMessage,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods,
            initialServingsInfo: initialServingsInfo
        ) {
            return agentResolution
        }

        return await legacyResolveLoggedCandidate(
            mention: mention,
            userMessage: userMessage,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods,
            initialServingsInfo: initialServingsInfo
        )
    }

    private func highConfidenceSearchResolution(
        mention: String,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        initialServingsInfo: ServingsInfo
    ) async -> CandidateResolution? {
        let candidates = await searchCandidates(
            query: mention,
            recentEntries: recentEntries,
            customFoods: customFoods
        )
        guard let candidate = candidates.first else { return nil }

        let brandPhrase = potentialBrandPhrase(in: mention)
        let brandMatched = brandPhrase != nil
            && (candidate.brand?.lowercased().contains(brandPhrase!) ?? false)

        if (candidate.portionBasis == .grams && candidate.score >= 48)
            || (brandMatched && candidate.score >= 48) {
            if brandMatched || isFoodFamilyMatch(candidate, mention: mention) {
                return CandidateResolution(
                    candidate: candidate,
                    servingsInfo: initialServingsInfo
                )
            }
        }
        return nil
    }

    private func isFoodFamilyMatch(_ candidate: SearchCandidate, mention: String) -> Bool {
        let mentionTokens = Set(identityTokens(in: mention).map(singularized))
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))

        if mentionTokens.contains("egg"),
           candidateTokens.contains("egg"),
           candidateTokens.contains("whole"),
           candidate.brand?.isEmpty != false {
            return true
        }

        if mentionTokens.contains("spinach"),
           candidateTokens.contains("spinach"),
           candidate.brand?.isEmpty != false {
            return true
        }

        return false
    }

    private func serverResolveLoggedCandidate(
        mention: String,
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        initialServingsInfo: ServingsInfo
    ) async -> CandidateResolution? {
        let resolved: ResolvedFoodCandidate
        do {
            resolved = try await provider.resolveFoodCandidate(
                userMessage: userMessage,
                foodMention: mention
            )
        } catch let error as ResolveFoodCandidateError where error == .unsupported {
            return nil
        } catch {
            return nil
        }

        guard let candidate = await resolveCandidate(
            candidateId: resolved.candidateId,
            recentEntries: recentEntries,
            customFoods: customFoods
        ) else {
            return nil
        }

        let localName = normalizedForComparison(candidate.name)
        let remoteName = normalizedForComparison(resolved.name)
        guard !localName.isEmpty, localName == remoteName else {
            return nil
        }

        let localBrand = normalizedForComparison(candidate.brand ?? "")
        let remoteBrand = normalizedForComparison(resolved.brand ?? "")
        if !localBrand.isEmpty || !remoteBrand.isEmpty, localBrand != remoteBrand {
            return nil
        }

        return CandidateResolution(
            candidate: candidate,
            servingsInfo: ServingsInfo(
                servings: max(0.1, resolved.servings),
                portionDescription: resolved.portionDescription.isEmpty ? initialServingsInfo.portionDescription : resolved.portionDescription,
                servingUnit: resolvedServingUnit(resolved.servingUnit),
                confident: resolved.confident,
                hasExplicitPortion: resolved.hasExplicitPortion || initialServingsInfo.hasExplicitPortion
            )
        )
    }

    /// Run the LLM-driven find-food agent loop. The LLM proposes the search
    /// query, looks at the candidates we returned, and either picks one or
    /// asks for another search. Capped at a small number of rounds.
    /// Returns nil when the agent gives up, the provider doesn't support the
    /// loop, or anything malformed happens — the caller will then fall back
    /// to the legacy resolver.
    private func agentResolveLoggedCandidate(
        mention: String,
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        initialServingsInfo: ServingsInfo
    ) async -> CandidateResolution? {
        var history: [AgentSearchRound] = []
        var seenQueries = Set<String>()
        let maxRounds = 4

        for _ in 0..<maxRounds {
            let outcome = await fetchAgentStep(
                provider: provider,
                userMessage: userMessage,
                mention: mention,
                history: history
            )
            switch outcome {
            case .step(let step):
                if case .search(let query) = step {
                    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized.isEmpty || !seenQueries.insert(normalized.lowercased()).inserted {
                        return nil
                    }
                    let candidates = await searchCandidates(
                        query: normalized,
                        recentEntries: recentEntries,
                        customFoods: customFoods
                    )
                    history.append(AgentSearchRound(query: normalized, candidates: candidates))
                    continue
                }
                if case .pick(let roundIndex, let candidateIndex, let servingsInfo) = step {
                    guard history.indices.contains(roundIndex) else { return nil }
                    let round = history[roundIndex]
                    let roundCandidates = round.candidates
                    guard roundCandidates.indices.contains(candidateIndex) else { return nil }
                    let merged = ServingsInfo(
                        servings: max(0.1, servingsInfo.servings),
                        portionDescription: servingsInfo.portionDescription.isEmpty ? "1 serving" : servingsInfo.portionDescription,
                        servingUnit: resolvedServingUnit(servingsInfo.servingUnit),
                        confident: servingsInfo.confident,
                        hasExplicitPortion: servingsInfo.hasExplicitPortion || initialServingsInfo.hasExplicitPortion
                    )

                    let validated = await validateLoggedCandidate(
                        candidate: roundCandidates[candidateIndex],
                        searchQuery: round.query,
                        mention: mention,
                        userMessage: userMessage,
                        servingsInfo: merged,
                        provider: provider
                    )

                    if let replacementQuery = validated.replacementSearchQuery {
                        let normalized = replacementQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        if normalized.isEmpty || !seenQueries.insert(normalized.lowercased()).inserted {
                            return nil
                        }
                        let candidates = await searchCandidates(
                            query: normalized,
                            recentEntries: recentEntries,
                            customFoods: customFoods
                        )
                        history.append(AgentSearchRound(query: normalized, candidates: candidates))
                        continue
                    }

                    guard validated.accepted else { return nil }

                    return CandidateResolution(
                        candidate: roundCandidates[candidateIndex],
                        servingsInfo: validated.servingsInfo
                    )
                }
                // .giveUp
                return nil
            case .unsupported:
                return nil
            case .failed:
                return nil
            }
        }

        return nil
    }

    /// Wrap the throwing call in a non-throwing helper so the callsite stays
    /// flat — Swift's deferred-init pattern with do/catch around an async
    /// throwing call has bitten us in this file before.
    private func fetchAgentStep(
        provider: any LLMProvider,
        userMessage: String,
        mention: String,
        history: [AgentSearchRound]
    ) async -> AgentStepOutcome {
        let payload = history.map { round in
            FindFoodHistoryRound(
                query: round.query,
                candidates: Array(round.candidates.prefix(20)).map { candidate in
                    FoodChoiceOption(
                        name: candidate.name,
                        brand: candidate.brand,
                        servingDescription: candidate.servingDesc,
                        caloriesPerServing: candidate.caloriesPerServing,
                        source: candidate.databaseSource,
                        portionBasis: candidate.portionBasis.rawValue
                    )
                }
            )
        }
        do {
            let step = try await provider.findFoodStep(
                userMessage: userMessage,
                foodMention: mention,
                history: payload
            )
            return .step(step)
        } catch let error as FindFoodStepError where error == .unsupported {
            return .unsupported
        } catch {
            return .failed
        }
    }

    private func legacyResolveLoggedCandidate(
        mention: String,
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        initialServingsInfo: ServingsInfo
    ) async -> CandidateResolution? {
        let initialQuery: String
        do {
            initialQuery = try await provider.buildFoodSearchQuery(
                userMessage: userMessage,
                foodMention: mention
            )
        } catch {
            initialQuery = mention
        }

        var searchQuery = initialQuery
        var servingsInfo = initialServingsInfo
        var seenQueries = Set<String>()
        var attempts = 0

        while attempts < 3 {
            let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedQuery.isEmpty else { break }
            guard seenQueries.insert(normalizedQuery.lowercased()).inserted else { break }

            let candidates = await searchCandidates(
                query: normalizedQuery,
                recentEntries: recentEntries,
                customFoods: customFoods
            )
            guard !candidates.isEmpty else { return nil }

            var candidate = await chooseCandidate(
                from: candidates,
                userMessage: userMessage,
                foodMention: mention,
                provider: provider
            )
            if candidate == nil {
                candidate = await fallbackCandidate(
                    from: candidates,
                    userMessage: userMessage,
                    foodMention: mention,
                    provider: provider
                )
            }
            guard let candidate = candidate else { return nil }

            let validated = await validateLoggedCandidate(
                candidate: candidate,
                searchQuery: normalizedQuery,
                mention: mention,
                userMessage: userMessage,
                servingsInfo: servingsInfo,
                provider: provider
            )
            servingsInfo = validated.servingsInfo

            if let replacementQuery = validated.replacementSearchQuery,
               replacementQuery.lowercased() != normalizedQuery.lowercased() {
                searchQuery = replacementQuery
                attempts += 1
                continue
            }

            guard validated.accepted else { return nil }

            return CandidateResolution(candidate: candidate, servingsInfo: servingsInfo)
        }

        return nil
    }

    private func fallbackCandidate(
        from candidates: [SearchCandidate],
        userMessage: String,
        foodMention: String,
        provider: any LLMProvider
    ) async -> SearchCandidate? {
        guard let bestCandidate = candidates.first else { return nil }

        let isMatch: Bool
        do {
            isMatch = try await provider.confirmFoodMatch(
                userMessage: userMessage,
                foodMention: foodMention,
                candidateName: bestCandidate.name,
                candidateBrand: bestCandidate.brand
            )
        } catch {
            isMatch = true
        }

        return isMatch ? bestCandidate : (candidates.dropFirst().first ?? bestCandidate)
    }

    private func validateLoggedCandidate(
        candidate: SearchCandidate,
        searchQuery: String,
        mention: String,
        userMessage: String,
        servingsInfo: ServingsInfo,
        provider: any LLMProvider
    ) async -> (accepted: Bool, servingsInfo: ServingsInfo, replacementSearchQuery: String?) {
        let option = FoodChoiceOption(
            name: candidate.name,
            brand: candidate.brand,
            servingDescription: candidate.servingDesc,
            caloriesPerServing: candidate.caloriesPerServing,
            source: candidate.databaseSource,
            portionBasis: candidate.portionBasis.rawValue
        )

        do {
            let validation = try await provider.validateFoodCandidate(
                userMessage: userMessage,
                foodMention: mention,
                searchQuery: searchQuery,
                candidate: option,
                servingsInfo: servingsInfo
            )
            return (
                accepted: validation.keepCurrentCandidate,
                servingsInfo: ServingsInfo(
                    servings: max(0.1, validation.servings),
                    portionDescription: validation.portionDescription,
                    servingUnit: resolvedServingUnit(validation.servingUnit),
                    confident: validation.confident,
                    hasExplicitPortion: validation.hasExplicitPortion
                ),
                replacementSearchQuery: validation.keepCurrentCandidate
                    ? nil
                    : validation.replacementSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        } catch {
            return (true, servingsInfo, nil)
        }
    }

    private func chooseCandidate(
        from candidates: [SearchCandidate],
        userMessage: String,
        foodMention: String,
        provider: any LLMProvider
    ) async -> SearchCandidate? {
        guard !candidates.isEmpty else { return nil }

        let shortlist = Array(candidates.prefix(10))
        do {
            let choiceIndex = try await provider.chooseFoodCandidate(
                userMessage: userMessage,
                foodMention: foodMention,
                candidates: shortlist.map {
                    FoodChoiceOption(
                        name: $0.name,
                        brand: $0.brand,
                        servingDescription: $0.servingDesc,
                        caloriesPerServing: $0.caloriesPerServing,
                        source: $0.databaseSource,
                        portionBasis: $0.portionBasis.rawValue
                    )
                }
            )
            if let choiceIndex, shortlist.indices.contains(choiceIndex) {
                return shortlist[choiceIndex]
            }
        } catch {
            // Fall back to the existing match check and ranking below.
        }

        if let best = shortlist.first {
            do {
                let isMatch = try await provider.confirmFoodMatch(
                    userMessage: userMessage,
                    foodMention: foodMention,
                    candidateName: best.name,
                    candidateBrand: best.brand
                )
                if isMatch {
                    return best
                }
                return shortlist.dropFirst().first ?? best
            } catch {
                return best
            }
        }

        return shortlist.first
    }

    private func canEditDirectly(_ entry: FoodEntry) -> Bool {
        entry.portionGrams > 0 && entry.caloriesPer100g > 0
    }

    private func estimateGrams(
        for candidate: SearchCandidate,
        portionDescription: String,
        provider: any LLMProvider,
        referenceServingDescription: String?,
        referenceServingGrams: Double?
    ) async -> Double {
        if portionDescription.lowercased() == "1 serving" {
            return candidate.servingGrams ?? max(referenceServingGrams ?? 0, 1)
        }

        do {
            return try await provider.estimateGrams(
                foodName: candidate.name,
                portionDescription: portionDescription,
                referenceServingDescription: referenceServingDescription,
                referenceServingGrams: referenceServingGrams
            )
        } catch {
            if candidate.canScaleByGrams {
                return max(candidate.servingGrams ?? referenceServingGrams ?? 0, 1)
            }
            return max(referenceServingGrams ?? candidate.servingGrams ?? 0, 1)
        }
    }

    private func resolvedServingUnit(_ servingUnit: String) -> String {
        let trimmed = servingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "serving" : trimmed
    }

    private func loggedEntry(
        for candidate: SearchCandidate,
        mention _: String,
        userMessage: String,
        meal: String,
        servingsInfo: ServingsInfo,
        provider: any LLMProvider,
        recentEntries _: [FoodEntry],
        customFoods _: [CustomFood]
    ) async -> FoodEntry? {
        let grams: Double
        let nutrition: NutritionValues

        if candidate.canScaleByGrams {
            grams = await estimateGrams(
                for: candidate,
                portionDescription: servingsInfo.portionDescription,
                provider: provider,
                referenceServingDescription: candidate.servingDesc,
                referenceServingGrams: candidate.servingGrams
            )
            nutrition = candidate.scaled(to: grams)
        } else {
            grams = candidate.servingGrams ?? 0
            nutrition = candidate.nutritionForServings(servingsInfo.servings)
        }

        return buildEntry(
            from: candidate,
            meal: meal,
            userMessage: userMessage,
            servingsInfo: servingsInfo,
            grams: grams,
            nutrition: nutrition
        )
    }

    private func buildEntry(
        from candidate: SearchCandidate,
        meal: String,
        userMessage: String,
        servingsInfo: ServingsInfo,
        grams: Double,
        nutrition: NutritionValues
    ) -> FoodEntry {
        let per100 = candidate.per100g
        return FoodEntry(
            name: candidate.name,
            brand: candidate.brand,
            meal: meal,
            portionGrams: grams,
            portionDescription: servingsInfo.portionDescription,
            servings: servingsInfo.servings,
            servingUnit: resolvedServingUnit(servingsInfo.servingUnit),
            calories: nutrition.calories,
            proteinG: nutrition.protein,
            carbsG: nutrition.carbs,
            fatG: nutrition.fat,
            fiberG: nutrition.fiber,
            sugarG: nutrition.sugar,
            sodiumMg: nutrition.sodium,
            saturatedFatG: nutrition.saturatedFat,
            transFatG: nutrition.transFat,
            cholesterolMg: nutrition.cholesterol,
            addedSugarG: nutrition.addedSugar,
            vitaminDMcg: nutrition.vitaminD,
            calciumMg: nutrition.calcium,
            ironMg: nutrition.iron,
            potassiumMg: nutrition.potassium,
            vitaminAMcgRAE: nutrition.vitaminA,
            vitaminCMg: nutrition.vitaminC,
            vitaminB12Mcg: nutrition.vitaminB12,
            folateMcgDFE: nutrition.folate,
            magnesiumMg: nutrition.magnesium,
            zincMg: nutrition.zinc,
            caloriesPer100g: per100.calories,
            proteinPer100g: per100.protein,
            carbsPer100g: per100.carbs,
            fatPer100g: per100.fat,
            fiberPer100g: per100.fiber,
            sugarPer100g: per100.sugar,
            sodiumPer100g: per100.sodium,
            saturatedFatPer100g: per100.saturatedFat,
            transFatPer100g: per100.transFat,
            cholesterolPer100g: per100.cholesterol,
            addedSugarPer100g: per100.addedSugar,
            vitaminDPer100g: per100.vitaminD,
            calciumPer100g: per100.calcium,
            ironPer100g: per100.iron,
            potassiumPer100g: per100.potassium,
            vitaminAPer100g: per100.vitaminA,
            vitaminCPer100g: per100.vitaminC,
            vitaminB12Per100g: per100.vitaminB12,
            folatePer100g: per100.folate,
            magnesiumPer100g: per100.magnesium,
            zincPer100g: per100.zinc,
            rawUserInput: userMessage,
            fdcId: candidate.fdcId,
            foodDatabaseId: candidate.source == .database ? Int(candidate.candidateId.replacingOccurrences(of: "db_", with: "")) : nil,
            source: candidate.source.rawValue,
            barcode: candidate.barcode
        )
    }

    // MARK: - Delete Food

    private func handleDeleteFood(
        userMessage: String,
        provider: any LLMProvider,
        dayEntries: [FoodEntry],
        dayLabel: String,
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        let logSummary = dayEntries.map { "\($0.name) (\($0.meal))" }.joined(separator: "\n")
        guard !logSummary.isEmpty else {
            return .reply("Your log for \(dayLabel) is empty — nothing to delete.")
        }

        do {
            let targets = try await provider.pickDeleteTargets(
                userMessage: userMessage,
                logSummary: logSummary,
                recentMessages: recentMessages
            )
            if targets.isEmpty {
                return .reply("I couldn't figure out what to delete. Could you be more specific?")
            }
            return .init(action: .deleteEntry(foodNames: targets), reply: "✓ Removed: \(targets.joined(separator: ", "))")
        } catch {
            return .reply("I had trouble processing that delete request. Try again?")
        }
    }

    // MARK: - Query Data

    private func handleQuery(
        userMessage: String,
        provider: any LLMProvider,
        goals: DailyGoal,
        dayEntries: [FoodEntry],
        dayLabel: String,
        recentEntries: [FoodEntry],
        weightEntries: [WeightEntry],
        waterEntries: [WaterEntry] = [],
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        let context = buildDataContext(
            goals: goals,
            dayEntries: dayEntries,
            dayLabel: dayLabel,
            recentEntries: recentEntries,
            weightEntries: weightEntries,
            waterEntries: waterEntries
        )

        do {
            let reply = try await provider.generalReply(
                userMessage: userMessage,
                context: context,
                recentMessages: recentMessages
            )
            return .reply(reply)
        } catch {
            let eaten = dayEntries.reduce(0.0) { $0 + $1.calories }
            return .reply("You've eaten \(Int(eaten)) of \(Int(goals.calories)) calories on \(dayLabel).")
        }
    }

    // MARK: - Rich Data Context Builder

    /// Builds a comprehensive context string with the user's full data history
    /// so the LLM can answer questions about weight trends, food patterns, averages, etc.
    private func buildDataContext(
        goals: DailyGoal,
        dayEntries: [FoodEntry],
        dayLabel: String,
        recentEntries: [FoodEntry],
        weightEntries: [WeightEntry],
        waterEntries: [WaterEntry] = []
    ) -> String {
        let cal = Calendar.current
        var sections: [String] = []

        // ── 1. Goals ──────────────────────────────────────────────────────
        sections.append("GOALS: \(Int(goals.calories)) cal, \(Int(goals.protein))g protein, \(Int(goals.carbs))g carbs, \(Int(goals.fat))g fat, \(Int(goals.fiber))g fiber.")

        // ── 2. Selected day — full detail ─────────────────────────────────
        let eaten    = dayEntries.reduce(0.0) { $0 + $1.calories }
        let protein  = dayEntries.reduce(0.0) { $0 + $1.proteinG }
        let carbs    = dayEntries.reduce(0.0) { $0 + $1.carbsG }
        let fat      = dayEntries.reduce(0.0) { $0 + $1.fatG }
        let fiber    = dayEntries.reduce(0.0) { $0 + $1.fiberG }

        var daySection = "SELECTED DAY (\(dayLabel)): \(Int(eaten))/\(Int(goals.calories)) cal, \(Int(protein))g protein, \(Int(carbs))g carbs, \(Int(fat))g fat, \(Int(fiber))g fiber. Remaining: \(Int(goals.calories - eaten)) cal."
        if !dayEntries.isEmpty {
            let items = dayEntries.map { "\($0.name) (\($0.portionDescription)) — \(Int($0.calories)) cal, \(Int($0.proteinG))g P / \(Int($0.carbsG))g C / \(Int($0.fatG))g F [\($0.meal)]" }
            daySection += "\nItems: " + items.joined(separator: "; ")
        }
        sections.append(daySection)

        // ── 3. Daily food history (last 30 days) ──────────────────────────
        // Group recentEntries by calendar day, summarize each day as one line.
        let selectedDayStart = cal.startOfDay(for: dayEntries.first?.date ?? Date())
        let grouped = Dictionary(grouping: recentEntries) { cal.startOfDay(for: $0.date) }
        let sortedDays = grouped.keys.sorted(by: >)

        var dailySummaries: [String] = []
        for day in sortedDays.prefix(30) {
            // Skip the selected day — already shown in detail above
            if day == selectedDayStart { continue }
            let entries = grouped[day]!
            let dayCal     = entries.reduce(0.0) { $0 + $1.calories }
            let dayProtein = entries.reduce(0.0) { $0 + $1.proteinG }
            let dayCarbs   = entries.reduce(0.0) { $0 + $1.carbsG }
            let dayFat     = entries.reduce(0.0) { $0 + $1.fatG }
            let label = Self.dayContextLabel(for: day)
            let topFoods = entries.prefix(6).map { $0.name }.joined(separator: ", ")
            dailySummaries.append("  \(label): \(Int(dayCal)) cal, \(Int(dayProtein))g P, \(Int(dayCarbs))g C, \(Int(dayFat))g F — \(entries.count) items (\(topFoods))")
        }
        if !dailySummaries.isEmpty {
            sections.append("FOOD HISTORY (last 30 days):\n" + dailySummaries.joined(separator: "\n"))
        }

        // ── 4. Weight history (last 90 entries) ──────────────────────────
        let sortedWeights = weightEntries.sorted { $0.date > $1.date }
        if !sortedWeights.isEmpty {
            let weightLines = sortedWeights.prefix(90).map { entry in
                let dateStr = Self.dayContextLabel(for: entry.date)
                let note = (entry.note ?? "").isEmpty ? "" : " (\(entry.note!))"
                return "  \(dateStr): \(String(format: "%.1f", entry.weightLbs)) lbs\(note)"
            }
            sections.append("WEIGHT HISTORY (\(sortedWeights.count) entries):\n" + weightLines.joined(separator: "\n"))
        } else {
            sections.append("WEIGHT HISTORY: No weight entries logged yet.")
        }

        // ── 5. Water / hydration history (last 30 days) ──────────────
        if !waterEntries.isEmpty {
            let waterGoalOz = UserDefaults.standard.double(forKey: "water_goal_oz")
            let goalDisplay = waterGoalOz > 0 ? waterGoalOz : 64.0
            let grouped = Dictionary(grouping: waterEntries) { cal.startOfDay(for: $0.date) }
            let sortedDays = grouped.keys.sorted(by: >)
            let waterLines = sortedDays.prefix(30).map { day -> String in
                let total = grouped[day]!.reduce(0) { $0 + $1.amountOz }
                let label = Self.dayContextLabel(for: day)
                return "  \(label): \(Int(total)) oz"
            }
            sections.append("HYDRATION (goal: \(Int(goalDisplay)) oz/day, last 30 days):\n" + waterLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Log Weight

    // MARK: - Log Water

    private func handleLogWater(
        userMessage: String,
        provider: any LLMProvider,
        waterEntries: [WaterEntry],
        targetDate: Date
    ) async -> LoggingResult {
        if let parsed = try? await provider.extractWaterMutation(userMessage: userMessage) {
            switch parsed.action {
            case "delete_all":
                return .init(action: .deleteWater, reply: "✓ Cleared today's water log.")
            case "update_total":
                guard let targetOz = parsed.amountOz, targetOz > 0 else {
                    return .reply("How many ounces should I set your water total to?")
                }
                return .init(
                    action: .setWaterTotal(oz: roundedTenth(targetOz)),
                    reply: "✓ Set today's water total to \(Int(targetOz.rounded())) oz."
                )
            case "add":
                if let amount = parsed.amountOz, amount > 0 {
                    let roundedOz = roundedTenth(amount)
                    let todayTotal = waterTotal(for: targetDate, entries: waterEntries) + roundedOz
                    return .init(
                        action: .logWater(oz: roundedOz),
                        reply: "✓ Logged \(Int(roundedOz.rounded())) oz of water. Today's total: \(Int(todayTotal.rounded())) oz."
                    )
                }
            default:
                break
            }
        }

        let msg = userMessage.lowercased()
        // Check for "delete" / "remove" / "clear" water
        if msg.contains("delete") || msg.contains("remove") || msg.contains("clear") {
            return .init(action: .deleteWater, reply: "✓ Cleared today's water log.")
        }

        // Try to extract a number — look for oz or ml amounts
        let pattern = #"(\d+\.?\d*)\s*(oz|ounce|ounces|ml|milliliter|milliliters|cup|cups|glass|glasses|bottle|bottles|liter|liters|l\b)?"#
        guard let match = msg.range(of: pattern, options: .regularExpression) else {
            // Default: log 8 oz (one glass)
            return .init(action: .logWater(oz: 8), reply: "✓ Logged 8 oz of water.")
        }

        let matched = String(msg[match])
        let numPattern = #"\d+\.?\d*"#
        guard let numMatch = matched.range(of: numPattern, options: .regularExpression),
              var amount = Double(matched[numMatch]) else {
            return .init(action: .logWater(oz: 8), reply: "✓ Logged 8 oz of water.")
        }

        // Convert common units to oz
        if matched.contains("ml") || matched.contains("milliliter") {
            amount = amount / 29.5735  // ml to oz
        } else if matched.contains("cup") || matched.contains("glass") {
            amount = amount * 8  // cups/glasses to oz
        } else if matched.contains("liter") || matched.hasSuffix("l") {
            amount = amount * 33.814  // liters to oz
        } else if matched.contains("bottle") {
            amount = amount * 16.9  // standard bottle ≈ 16.9 oz
        }

        let roundedOz = roundedTenth(amount)
        let todayTotal = waterTotal(for: targetDate, entries: waterEntries) + roundedOz

        return .init(
            action: .logWater(oz: roundedOz),
            reply: "✓ Logged \(Int(roundedOz)) oz of water. Today's total: \(Int(todayTotal)) oz."
        )
    }

    private func waterTotal(for date: Date, entries: [WaterEntry]) -> Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return entries
            .filter { $0.date >= start && $0.date < end }
            .reduce(0) { $0 + $1.amountOz }
    }

    private func roundedTenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func handleLogWeight(
        userMessage: String,
        provider: any LLMProvider,
        weightEntries: [WeightEntry],
        targetDate: Date
    ) async -> LoggingResult {
        if let parsed = try? await provider.extractWeightMutation(userMessage: userMessage) {
            switch parsed.action {
            case "delete_all":
                return .init(action: .deleteAllWeights, reply: "✓ Cleared all weight entries.")
            case "delete":
                if let target = weightTarget(from: parsed.dateHint, targetDate: targetDate, entries: weightEntries) {
                    return .init(action: .deleteWeight(date: target.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()), reply: "✓ Deleted \(weightDateLabel(target.date)) weight entry.")
                }
                return .reply("I couldn't find a matching weight entry to delete.")
            case "update":
                guard let weight = parsed.weightLbs, weight > 50, weight < 1000 else {
                    return .reply("What weight should I update it to?")
                }
                if let target = weightTarget(from: parsed.dateHint, targetDate: targetDate, entries: weightEntries) {
                    return .init(
                        action: .updateWeight(id: target.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(), weightLbs: weight),
                        reply: "✓ Updated \(weightDateLabel(target.date)) weight to \(String(format: "%.1f", weight)) lbs."
                    )
                }
                return .init(
                    action: .log_weight(WeightEntry(weightLbs: weight)),
                    reply: "✓ Logged \(String(format: "%.1f", weight)) lbs."
                )
            case "add":
                if let weight = parsed.weightLbs, weight > 50, weight < 1000 {
                    return .init(
                        action: .log_weight(WeightEntry(weightLbs: weight)),
                        reply: "✓ Logged \(String(format: "%.1f", weight)) lbs."
                    )
                }
            default:
                break
            }
        }

        // Try to find a decimal number pattern
        let pattern = #"(\d+\.?\d*)\s*(lbs?|pounds?|kg|kilos?)?"#
        if let match = userMessage.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let weightStr = String(userMessage[match])
            let numPattern = #"\d+\.?\d*"#
            if let numMatch = weightStr.range(of: numPattern, options: .regularExpression) {
                let weight = Double(weightStr[numMatch]) ?? 0
                if weight > 50 && weight < 1000 {
                    return .init(
                        action: .log_weight(WeightEntry(weightLbs: weight)),
                        reply: "✓ Logged \(String(format: "%.1f", weight)) lbs."
                    )
                }
            }
        }
        return .reply("I couldn't understand the weight. Try something like \"I weigh 180 lbs\".")
    }

    private func weightTarget(from hint: String?, targetDate: Date, entries: [WeightEntry]) -> WeightEntry? {
        guard !entries.isEmpty else { return nil }
        let cal = Calendar.current
        let targetDay: Date
        switch hint {
        case "yesterday":
            targetDay = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: targetDate)) ?? targetDate
        case "today":
            targetDay = targetDate
        case "latest", nil:
            return entries.sorted { $0.date > $1.date }.first
        default:
            return entries.sorted { $0.date > $1.date }.first
        }
        let start = cal.startOfDay(for: targetDay)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return entries
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.date > $1.date }
            .first
    }

    private func weightDateLabel(_ date: Date) -> String {
        Self.dayContextLabel(for: date)
    }

    // MARK: - Set Goal

    private func handleSetGoal(
        userMessage: String,
        provider: any LLMProvider,
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        // Let GPT parse the goal — it understands natural language better than regex
        guard let remoteProvider = provider as? RemoteAPIProvider else {
            return .reply("Goal setting requires an internet connection.")
        }

        do {
            let goal = try await remoteProvider.extractGoal(userMessage: userMessage)

            var parts: [String] = []
            if let c = goal.calories { parts.append("\(Int(c)) cal") }
            if let p = goal.protein { parts.append("\(Int(p))g protein") }
            if let c = goal.carbs { parts.append("\(Int(c))g carbs") }
            if let f = goal.fat { parts.append("\(Int(f))g fat") }
            if let f = goal.fiber { parts.append("\(Int(f))g fiber") }

            if parts.isEmpty {
                return .reply("I couldn't figure out what goal to set. Try \"set protein to 150g\" or \"set calories to 2000\".")
            }

            return .init(
                action: .setGoal(calories: goal.calories, protein: goal.protein, carbs: goal.carbs, fat: goal.fat, fiber: goal.fiber),
                reply: "✓ Goals updated: \(parts.joined(separator: ", "))."
            )
        } catch {
            return .reply("I had trouble parsing that goal. Try \"set protein to 150g\" or \"set calories to 2000\".")
        }
    }

    // MARK: - General Reply

    private func handleGeneralReply(
        userMessage: String,
        provider: any LLMProvider,
        goals: DailyGoal,
        dayEntries: [FoodEntry],
        dayLabel: String,
        recentEntries: [FoodEntry],
        weightEntries: [WeightEntry],
        waterEntries: [WaterEntry] = [],
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        let context = buildDataContext(
            goals: goals,
            dayEntries: dayEntries,
            dayLabel: dayLabel,
            recentEntries: recentEntries,
            weightEntries: weightEntries,
            waterEntries: waterEntries
        )

        do {
            let reply = try await provider.generalReply(
                userMessage: userMessage,
                context: context,
                recentMessages: recentMessages
            )
            return .reply(reply)
        } catch {
            return .reply("Hi! I'm Nomva. Tell me what you ate and I'll log it for you.")
        }
    }

    private func handleProviderError(_ error: Error) -> LoggingResult {
        let isOffline = !NetworkMonitor.shared.isConnected
        if isOffline {
            return .reply("No internet connection. Please check your network and try again. You can still log food manually in the Log tab!")
        }
        
        print("❌ AI Service Error: \(error.localizedDescription)")
        return .reply("I'm having trouble connecting to my brain right now. Could you try again in a moment? You can always log food manually in the Log tab if you're in a hurry.")
    }

    private static func dayContextLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return "today"
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM d, yyyy")
        return formatter.string(from: date)
    }

    func searchFoodsForManualEntry(query: String, limit: Int = 30) async -> [FoodItem] {
        let candidates = await searchCandidates(
            query: query,
            recentEntries: [],
            customFoods: [],
            limit: limit
        )
        return candidates.compactMap(databaseFood(from:))
    }

    private func searchCandidates(
        query: String,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        limit: Int = 10
    ) async -> [SearchCandidate] {
        var merged = [String: SearchCandidate]()

        for variant in searchVariants(for: query) {
            let primaryFoods = await db.search(query: variant, limit: 15)
            let looseFoods = await db.searchLoose(query: variant, limit: 15)
            let foods = primaryFoods + looseFoods
            for candidate in buildDatabaseCandidates(from: foods) {
                merged[candidate.candidateId] = merged[candidate.candidateId] ?? candidate
            }
        }

        for candidate in buildCustomCandidates(from: customFoods) {
            merged[candidate.candidateId] = merged[candidate.candidateId] ?? candidate
        }

        for candidate in buildRecentCandidates(from: recentEntries) {
            merged[candidate.candidateId] = merged[candidate.candidateId] ?? candidate
        }

        var scored = merged.values.map { candidate -> SearchCandidate in
            var copy = candidate
            copy.score = calculateScore(candidate, query: query)
            return copy
        }
        applyDensityOutlierPenalty(to: &scored, query: query)

        // Boost candidates whose brand or name contains the likely brand phrase
        if let brandPhrase = potentialBrandPhrase(in: query) {
            let lowerBrandPhrase = brandPhrase.lowercased()
            for i in scored.indices {
                let candidateLowerBrand = (scored[i].brand?.lowercased() ?? "")
                let candidateLowerName = scored[i].name.lowercased()
                if candidateLowerBrand.contains(lowerBrandPhrase) {
                    scored[i].score += 1000
                } else if candidateLowerName.contains(lowerBrandPhrase) {
                    scored[i].score += 800
                }
            }
        }

        scored.sort {
            if $0.score == $1.score {
                let leftQuality = servingQuality(for: $0)
                let rightQuality = servingQuality(for: $1)
                if leftQuality != rightQuality {
                    return leftQuality > rightQuality
                }
                return $0.name < $1.name
            }
            return $0.score > $1.score
        }

        if looksLikePlainWholeFoodQuery(query) {
            let literal = scored.filter { isLiteralWholeFoodMatch($0, query: query) }
            if !literal.isEmpty {
                return Array(literal.prefix(limit))
            }
            let simpleBase = scored.filter { isSimpleGenericBaseMatch($0, query: query) }
            if !simpleBase.isEmpty {
                return Array(simpleBase.prefix(limit))
            }
        }

        return Array(scored.prefix(limit))
    }

    private func calculateScore(_ candidate: SearchCandidate, query: String) -> Int {
        let tokens = meaningfulTokens(in: query)
        let normalizedQuery = normalizedForComparison(query)
        let name = normalizedForComparison(candidate.name)
        let brand = normalizedForComparison(candidate.brand ?? "")
        let genericQuery = looksLikeGenericFoodQuery(query)
        let plainWholeQuery = looksLikePlainWholeFoodQuery(query)
        let queryHasPreparation = tokens.contains { preparationWords.contains($0) }
        let countBased = isCountBased(query)
        var score = 0

        if name == normalizedQuery {
            score += 80
        } else if !normalizedQuery.isEmpty && name.hasPrefix(normalizedQuery + " ") {
            score += 45
        }

        let overlap = queryOverlapScore(query: query, candidateName: candidate.name, brand: candidate.brand)
        score += overlap * 12

        if genericQuery && (candidate.brand?.isEmpty != false) {
            score += 18
        }

        if genericQuery && (candidate.databaseSource?.contains("sr_legacy") == true) {
            score += 14
        }

        if genericQuery && candidate.portionBasis == .fixedServing {
            score -= 36
        }

        if candidate.databaseSource == "open_food_facts",
           (candidate.brand?.isEmpty != false),
           meaningfulTokens(in: candidate.name).count == 1 {
            score -= 160
        }

        if genericQuery && name.contains(" raw") {
            score += 16
        }

        if countBased, let servingGrams = candidate.servingGrams {
            if servingGrams < 15 {
                score -= 28
            } else if servingGrams >= 40 {
                score += 8
            }
        }

        if !queryHasPreparation {
            for word in suspiciousFormWords where name.contains(word) && !normalizedQuery.contains(word) {
                score -= 16
            }
        }

        if !genericQuery, !brand.isEmpty, normalizedQuery.contains(brand) {
            score += 18
        }

        if genericQuery || countBased {
            let extras = extraConceptTokens(in: candidate.name, comparedTo: query)
            let variantExtras = extras.filter { variantQualifierWords.contains($0) }
            let otherExtras = extras.filter { !variantQualifierWords.contains($0) && !baseDescriptorWords.contains($0) }

            if !variantExtras.isEmpty {
                score -= min(variantExtras.count * 22, 110)
            }

            if !otherExtras.isEmpty {
                score -= min(otherExtras.count * 14, 84)
            }
        }

        if plainWholeQuery {
            let extras = extraConceptTokens(in: candidate.name, comparedTo: query)
            let variantExtras = extras.filter { variantQualifierWords.contains($0) }
            let descriptorExtras = extras.filter { baseDescriptorWords.contains($0) }
            let otherExtras = extras.filter { !variantQualifierWords.contains($0) && !baseDescriptorWords.contains($0) }

            if !variantExtras.isEmpty {
                score -= min(variantExtras.count * 34, 102)
            }

            if !otherExtras.isEmpty {
                score -= min(otherExtras.count * 18, 72)
            }

            if candidate.databaseSource?.contains("sr_legacy") == true,
               variantExtras.isEmpty,
               otherExtras.isEmpty,
               !descriptorExtras.isEmpty {
                score += 28
            }

            if candidate.brand?.isEmpty == false {
                score -= 12
            }

            if candidate.databaseSource?.contains("branded") == true {
                score -= 10
            }
        }

        return score
    }

    private func applyDensityOutlierPenalty(to candidates: inout [SearchCandidate], query: String) {
        guard shouldApplyDensityPenalty(for: query) else { return }

        let densities = candidates.compactMap(calorieDensity(for:)).filter { $0 >= 20 && $0 <= 900 }
        guard densities.count >= 4 else { return }

        let baseline = median(of: densities)
        guard baseline > 0 else { return }

        for index in candidates.indices {
            guard let density = calorieDensity(for: candidates[index]) else { continue }
            let isLowOutlier = density < baseline * 0.45
            let isHighOutlier = density > baseline * 2.2
            guard isLowOutlier || isHighOutlier else { continue }
            guard candidates[index].brand?.isEmpty == false || candidates[index].databaseSource == "open_food_facts" else { continue }

            candidates[index].score -= isLowOutlier ? 48 : 28
        }
    }

    private func calorieDensity(for candidate: SearchCandidate) -> Double? {
        guard candidate.portionBasis == .grams,
              let grams = candidate.servingGrams,
              grams > 0,
              candidate.caloriesPerServing > 0 else {
            return nil
        }
        return candidate.caloriesPerServing / grams * 100
    }

    private func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private func shouldApplyDensityPenalty(for query: String) -> Bool {
        let tokens = meaningfulTokens(in: query)
        return !tokens.contains { nutritionModifierWords.contains($0) }
    }

    private func servingQuality(for candidate: SearchCandidate) -> Int {
        switch candidate.servingSource {
        case .explicitServing:
            return 3
        case .parsedServing:
            return 2
        case .fallbackRaw:
            if candidate.servingDesc?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "100g" {
                return 0
            }
            return 1
        case nil:
            return 0
        }
    }

    private func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .replacingOccurrences(of: "%", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func meaningfulTokens(in text: String) -> [String] {
        tokenize(text).filter { !fillerWords.contains($0) && !mealWords.contains($0) }
    }

    private func identityTokens(in text: String) -> [String] {
        meaningfulTokens(in: text).filter {
            !$0.allSatisfy(\.isNumber) && !countWords.contains($0) && !unitWords.contains($0)
        }
    }

    private func singularized(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count > 3 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("s"), token.count > 3, !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    private func normalizedForComparison(_ text: String) -> String {
        meaningfulTokens(in: text).joined(separator: " ")
    }

    private func normalizedSearchText(_ text: String) -> String {
        identityTokens(in: text).joined(separator: " ")
    }

    private func looksLikeGenericFoodQuery(_ query: String) -> Bool {
        let tokens = identityTokens(in: query)
        return !tokens.isEmpty && tokens.count <= 4 && !tokens.contains { preparationWords.contains($0) }
    }

    private func looksLikePlainWholeFoodQuery(_ query: String) -> Bool {
        let tokens = identityTokens(in: query)
        return !tokens.isEmpty && tokens.count <= 2 && !tokens.contains { preparationWords.contains($0) }
    }

    private func isCountBased(_ query: String) -> Bool {
        let tokens = tokenize(query)
        let hasCount = tokens.contains { $0.allSatisfy(\.isNumber) || countWords.contains($0) }
        let hasUnit = tokens.contains { unitWords.contains($0) }
        return hasCount && !hasUnit
    }

    private func queryOverlapScore(query: String, candidateName: String, brand: String?) -> Int {
        let queryTokens = Set(identityTokens(in: query).map(singularized))
        let nameTokens = Set(meaningfulTokens(in: candidateName).map(singularized))
        let brandTokens = Set(meaningfulTokens(in: brand ?? "").map(singularized))
        return queryTokens.intersection(nameTokens.union(brandTokens)).count
    }

    private func extraConceptTokens(in candidateName: String, comparedTo query: String) -> [String] {
        let queryTokens = Set(identityTokens(in: query).map(singularized))
        let candidateTokens = meaningfulTokens(in: candidateName).map(singularized)
        return candidateTokens.filter { !queryTokens.contains($0) && !wholeFoodNeutralWords.contains($0) }
    }

    private func isLiteralWholeFoodMatch(_ candidate: SearchCandidate, query: String) -> Bool {
        guard looksLikePlainWholeFoodQuery(query) else { return false }
        if candidate.brand?.isEmpty == false { return false }
        if candidate.databaseSource == "open_food_facts", meaningfulTokens(in: candidate.name).count == 1 {
            return false
        }
        if candidate.databaseSource?.contains("branded") == true {
            return false
        }

        let queryTokens = Set(identityTokens(in: query).map(singularized))
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))
        return !queryTokens.isEmpty
            && queryTokens.isSubset(of: candidateTokens)
            && extraConceptTokens(in: candidate.name, comparedTo: query).isEmpty
    }

    private func isSimpleGenericBaseMatch(_ candidate: SearchCandidate, query: String) -> Bool {
        guard looksLikePlainWholeFoodQuery(query) else { return false }
        if candidate.brand?.isEmpty == false { return false }
        if candidate.databaseSource == "open_food_facts", meaningfulTokens(in: candidate.name).count == 1 {
            return false
        }

        let queryTokens = Set(identityTokens(in: query).map(singularized))
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))
        guard !queryTokens.isEmpty, queryTokens.isSubset(of: candidateTokens) else { return false }

        let extras = extraConceptTokens(in: candidate.name, comparedTo: query)
        if extras.isEmpty {
            return true
        }
        if extras.contains(where: { variantQualifierWords.contains($0) }) {
            return false
        }
        return extras.allSatisfy { baseDescriptorWords.contains($0) }
    }

    private func searchVariants(for query: String) -> [String] {
        let coreTokens = identityTokens(in: query)
        var variants: [String] = []

        if !coreTokens.isEmpty {
            variants.append(coreTokens.joined(separator: " "))
        }

        let singularTokens = coreTokens.map(singularized)
        if !singularTokens.isEmpty {
            variants.append(singularTokens.joined(separator: " "))
        }

        let normalized = normalizedSearchText(query)
        if !normalized.isEmpty {
            variants.append(normalized)
        }

        if looksLikeGenericFoodQuery(query), !singularTokens.isEmpty {
            variants.append(singularTokens.joined(separator: " ") + " raw")
        }

        if coreTokens.count >= 3 {
            variants.append(coreTokens.dropFirst().joined(separator: " "))
        }

        variants.append(contentsOf: foodFamilySearchVariants(for: coreTokens))

        // Generic brand‑aware variants when a brand phrase can be extracted
        if let brandPhrase = potentialBrandPhrase(in: query) {
            let lowerBrandTokens = brandPhrase.split(separator: " ").map { String($0) }
            let remaining = coreTokens.filter { t in !lowerBrandTokens.contains(t.lowercased()) }
            let variant = ([brandPhrase] + remaining).joined(separator: " ")
            if !variant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                variants.append(variant)
            }

            // Also try a compact version without spaces inside the brand name
            let compactBrand = brandPhrase.replacingOccurrences(of: " ", with: "")
            if !compactBrand.isEmpty {
                let compactVariant = ([compactBrand] + remaining).joined(separator: " ")
                variants.append(compactVariant)
            }
        }

        var unique: [String] = []
        for variant in variants {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !unique.contains(trimmed) {
                unique.append(trimmed)
            }
        }
        return unique
    }

    private func foodFamilySearchVariants(for tokens: [String]) -> [String] {
        let singularTokens = Set(tokens.map(singularized))
        var variants: [String] = []

        let mentionsChicken = singularTokens.contains("chicken")
        let mentionsNuggets = singularTokens.contains("nugget")
        let mentionsFries = singularTokens.contains("fry") || singularTokens.contains("frie")

        if mentionsNuggets, mentionsChicken {
            variants.append("chicken nuggets")
        } else if mentionsNuggets, tokens.count == 1 {
            variants.append("chicken nuggets")
        }

        if mentionsFries, tokens.count <= 2 {
            variants.append("french fries")
        }

        if singularTokens.contains("egg") {
            variants.append("whole egg")
        }

        if singularTokens.contains("spinach") {
            variants.append("spinach raw")
        }

        return variants
    }

    private func resolveCandidate(candidateId: String, recentEntries: [FoodEntry], customFoods: [CustomFood]) async -> SearchCandidate? {
        if candidateId.hasPrefix("db_"), let id = Int(candidateId.replacingOccurrences(of: "db_", with: "")) {
            return (await db.food(byRowId: id)).map { buildDatabaseCandidates(from: [$0]).first! }
        }
        if candidateId.hasPrefix("usda_"), let id = Int(candidateId.replacingOccurrences(of: "usda_", with: "")) {
            return (await db.food(byFdcId: id)).map { buildDatabaseCandidates(from: [$0]).first! }
        }
        if candidateId.hasPrefix("custom_") {
            let suffix = candidateId.replacingOccurrences(of: "custom_", with: "")
            return customFoods.first { String($0.id.uuidString.prefix(10)) == suffix }.map { buildCustomCandidates(from: [$0]).first! }
        }
        if candidateId.hasPrefix("recent_") {
            let suffix = candidateId.replacingOccurrences(of: "recent_", with: "")
            return recentEntries.first { String($0.id.uuidString.prefix(10)) == suffix }.map { buildRecentCandidates(from: [$0]).first! }
        }
        return nil
    }

    private func databaseFood(from candidate: SearchCandidate) -> FoodItem? {
        guard candidate.source == .database,
              let rowId = Int(candidate.candidateId.replacingOccurrences(of: "db_", with: "")) else {
            return nil
        }

        return FoodItem(
            id: rowId,
            fdcId: candidate.fdcId,
            name: candidate.name,
            brand: candidate.brand,
            source: candidate.databaseSource,
            servingGrams: candidate.servingGrams,
            servingDesc: candidate.servingDesc,
            caloriesPerServing: candidate.caloriesPerServing,
            proteinG: candidate.proteinG,
            carbsG: candidate.carbsG,
            fatG: candidate.fatG,
            fiberG: candidate.fiberG,
            sugarG: candidate.sugarG,
            sodiumMg: candidate.sodiumMg,
            saturatedFatG: candidate.saturatedFatG,
            transFatG: candidate.transFatG,
            cholesterolMg: candidate.cholesterolMg,
            addedSugarG: candidate.addedSugarG,
            vitaminDMcg: candidate.vitaminDMcg,
            calciumMg: candidate.calciumMg,
            ironMg: candidate.ironMg,
            potassiumMg: candidate.potassiumMg,
            vitaminAMcgRAE: candidate.vitaminAMcgRAE,
            vitaminCMg: candidate.vitaminCMg,
            vitaminB12Mcg: candidate.vitaminB12Mcg,
            folateMcgDFE: candidate.folateMcgDFE,
            magnesiumMg: candidate.magnesiumMg,
            zincMg: candidate.zincMg,
            barcode: candidate.barcode,
            portionBasis: candidate.portionBasis,
            servingSource: candidate.servingSource
        )
    }

    private func buildDatabaseCandidates(from foods: [FoodItem]) -> [SearchCandidate] {
        foods.map {
            SearchCandidate(
                candidateId: "db_\($0.id)",
                source: CandidateSource.database,
                databaseSource: $0.source,
                fdcId: $0.fdcId,
                customFoodId: nil,
                recentEntryId: nil,
                name: $0.name,
                brand: $0.brand,
                servingGrams: $0.servingGrams,
                servingDesc: $0.servingDesc,
                caloriesPerServing: $0.caloriesPerServing,
                proteinG: $0.proteinG,
                carbsG: $0.carbsG,
                fatG: $0.fatG,
                fiberG: $0.fiberG,
                sugarG: $0.sugarG,
                sodiumMg: $0.sodiumMg,
                saturatedFatG: $0.saturatedFatG,
                transFatG: $0.transFatG,
                cholesterolMg: $0.cholesterolMg,
                addedSugarG: $0.addedSugarG,
                vitaminDMcg: $0.vitaminDMcg,
                calciumMg: $0.calciumMg,
                ironMg: $0.ironMg,
                potassiumMg: $0.potassiumMg,
                vitaminAMcgRAE: $0.vitaminAMcgRAE,
                vitaminCMg: $0.vitaminCMg,
                vitaminB12Mcg: $0.vitaminB12Mcg,
                folateMcgDFE: $0.folateMcgDFE,
                magnesiumMg: $0.magnesiumMg,
                zincMg: $0.zincMg,
                barcode: $0.barcode,
                portionBasis: $0.portionBasis,
                servingSource: $0.servingSource,
                per100gValues: $0.per100g
            )
        }
    }

    private func buildCustomCandidates(from foods: [CustomFood]) -> [SearchCandidate] {
        foods.map { SearchCandidate(candidateId: "custom_\(String($0.id.uuidString.prefix(10)))", source: CandidateSource.custom, databaseSource: nil, fdcId: nil, customFoodId: $0.id, recentEntryId: nil, name: $0.name, brand: $0.brand, servingGrams: $0.servingGrams, servingDesc: $0.servingDesc, caloriesPerServing: $0.calories, proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG, fiberG: $0.fiberG, sugarG: 0, sodiumMg: 0, saturatedFatG: nil, transFatG: nil, cholesterolMg: nil, addedSugarG: nil, vitaminDMcg: nil, calciumMg: nil, ironMg: nil, potassiumMg: nil, vitaminAMcgRAE: nil, vitaminCMg: nil, vitaminB12Mcg: nil, folateMcgDFE: nil, magnesiumMg: nil, zincMg: nil, barcode: nil, portionBasis: .grams, servingSource: nil, per100gValues: NutritionValues(calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0, sodium: 0)) }
    }

    private func buildRecentCandidates(from entries: [FoodEntry]) -> [SearchCandidate] {
        entries.prefix(10).map {
            let gramSafe = $0.portionGrams > 0 && $0.caloriesPer100g > 0
            return SearchCandidate(candidateId: "recent_\(String($0.id.uuidString.prefix(10)))", source: CandidateSource.recent, databaseSource: $0.source, fdcId: $0.fdcId, customFoodId: nil, recentEntryId: $0.id, name: $0.name, brand: $0.brand, servingGrams: $0.portionGrams, servingDesc: $0.portionDescription, caloriesPerServing: $0.calories, proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG, fiberG: $0.fiberG, sugarG: $0.sugarG, sodiumMg: $0.sodiumMg, saturatedFatG: $0.saturatedFatG, transFatG: $0.transFatG, cholesterolMg: $0.cholesterolMg, addedSugarG: $0.addedSugarG, vitaminDMcg: $0.vitaminDMcg, calciumMg: $0.calciumMg, ironMg: $0.ironMg, potassiumMg: $0.potassiumMg, vitaminAMcgRAE: $0.vitaminAMcgRAE, vitaminCMg: $0.vitaminCMg, vitaminB12Mcg: $0.vitaminB12Mcg, folateMcgDFE: $0.folateMcgDFE, magnesiumMg: $0.magnesiumMg, zincMg: $0.zincMg, barcode: $0.barcode, portionBasis: gramSafe ? .grams : .fixedServing, servingSource: nil, per100gValues: NutritionValues(calories: $0.caloriesPer100g, protein: $0.proteinPer100g, carbs: $0.carbsPer100g, fat: $0.fatPer100g, fiber: $0.fiberPer100g, sugar: $0.sugarPer100g, sodium: $0.sodiumPer100g, saturatedFat: $0.saturatedFatPer100g, transFat: $0.transFatPer100g, cholesterol: $0.cholesterolPer100g, addedSugar: $0.addedSugarPer100g, vitaminD: $0.vitaminDPer100g, calcium: $0.calciumPer100g, iron: $0.ironPer100g, potassium: $0.potassiumPer100g, vitaminA: $0.vitaminAPer100g, vitaminC: $0.vitaminCPer100g, vitaminB12: $0.vitaminB12Per100g, folate: $0.folatePer100g, magnesium: $0.magnesiumPer100g, zinc: $0.zincPer100g)) }
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

private extension FoodLoggingService.LoggingResult {
    static func reply(_ text: String) -> FoodLoggingService.LoggingResult {
        .init(action: .reply(text), reply: text)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
