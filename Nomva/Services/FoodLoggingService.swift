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

private enum ServerResolutionAttempt {
    case resolved(CandidateResolution)
    case noMatch
    case unavailable
}

private struct FastFoodMention {
    let text: String
    let servingsInfo: ServingsInfo
}

private struct FastFoodParse {
    let meal: String?
    let mentions: [FastFoodMention]
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
    "no", "yes", "item", "items", "dude", "actually", "instead", "meant", "wasn", "t",
    "log", "logged", "from", "about"
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

private let menuSizeWords: Set<String> = ["small", "medium", "large"]

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
        case replaceEntryById(deleteId: UUID, newEntries: [FoodEntry])
        case editEntry(foodName: String, newGrams: Double, newDescription: String, newServings: Double, newServingUnit: String)
        case deleteEntry(foodNames: [String])
        case deleteEntries(ids: [UUID])
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
    // Each step makes one focused call through the Nomva Cloud API.
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

        if let deletion = handleFastScopedFoodDelete(userMessage: userMessage) {
            return deletion
        }

        if let deletion = handleFastContextualDelete(
            userMessage: userMessage,
            dayEntries: dayEntries
        ) {
            return deletion
        }

        if let correction = await handleImplicitFoodIdentityCorrection(
            userMessage: userMessage,
            provider: provider,
            dayEntries: dayEntries,
            recentEntries: recentEntries,
            customFoods: customFoods
        ) {
            return correction
        }

        if await shouldFastRouteFoodLog(
            userMessage,
            recentEntries: recentEntries,
            customFoods: customFoods
        ) {
            return await handleLogFood(
                userMessage: userMessage,
                provider: provider,
                recentEntries: recentEntries,
                customFoods: customFoods
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

    private func handleFastContextualDelete(
        userMessage: String,
        dayEntries: [FoodEntry]
    ) -> LoggingResult? {
        guard !dayEntries.isEmpty else { return nil }
        let tokens = tokenize(userMessage).map(singularized)
        let tokenSet = Set(tokens)
        let deleteWords: Set<String> = ["delete", "remove", "clear"]
        guard !tokenSet.intersection(deleteWords).isEmpty else { return nil }
        guard !tokenSet.contains("water"), !tokenSet.contains("weight"), !tokenSet.contains("goal") else { return nil }
        guard !tokenSet.contains("all"), !tokenSet.contains("everything") else { return nil }

        let contextualWords: Set<String> = ["that", "it", "this", "last", "latest", "previous"]
        guard !tokenSet.intersection(contextualWords).isEmpty else { return nil }

        let commandNoise = deleteWords.union(contextualWords).union(["no", "not", "please", "added", "entry"])
        let requestedFoodTokens = Set(identityTokens(in: userMessage).map(singularized)).subtracting(commandNoise)
        let target: FoodEntry?
        let sortedEntries = dayEntries.sorted { $0.date > $1.date }

        if requestedFoodTokens.isEmpty {
            target = sortedEntries.first
        } else {
            target = sortedEntries.first { entry in
                let entryTokens = Set(identityTokens(in: "\(entry.brand ?? "") \(entry.name)").map(singularized))
                return !entryTokens.intersection(requestedFoodTokens).isEmpty
            }
        }

        guard let target else { return nil }
        return LoggingResult(
            action: .deleteEntries(ids: [target.id]),
            reply: "✓ Removed: \(target.name)"
        )
    }

    private func handleFastScopedFoodDelete(userMessage: String) -> LoggingResult? {
        let tokenSet = Set(tokenize(userMessage).map(singularized))
        let deleteWords: Set<String> = ["delete", "remove", "clear", "empty", "wipe"]
        guard !tokenSet.intersection(deleteWords).isEmpty else { return nil }
        guard !tokenSet.contains("water"), !tokenSet.contains("weight"), !tokenSet.contains("goal") else { return nil }

        if let requestedMeal = scopedMealDeleteTarget(in: userMessage) {
            return LoggingResult(
                action: .deleteMeal(meal: requestedMeal),
                reply: "✓ Removed \(requestedMeal) foods."
            )
        }

        guard isWholeDayFoodDelete(userMessage) else { return nil }

        return LoggingResult(
            action: .deleteMeal(meal: "all"),
            reply: "✓ Cleared today's food log."
        )
    }

    private func scopedMealDeleteTarget(in userMessage: String) -> String? {
        for meal in ["breakfast", "lunch", "dinner", "snack"] {
            let patterns = [
                #"(?i)^\s*(?:delete|remove|clear|empty|wipe)\s+(?:my\s+|the\s+)?\#(meal)\s*(?:foods?|meal|entries?|log)?\s*$"#,
                #"(?i)^\s*(?:delete|remove|clear|empty|wipe)\s+(?:all\s+)?(?:foods?|meals?|entries?)\s+(?:from|for|in)\s+(?:my\s+|the\s+)?\#(meal)\s*$"#,
                #"(?i)^\s*(?:delete|remove|clear|empty|wipe)\s+(?:my\s+|the\s+)?\#(meal)\s+(?:foods?|meal|entries?|log)\s*$"#
            ]
            if patterns.contains(where: { userMessage.range(of: $0, options: .regularExpression) != nil }) {
                return meal
            }
        }
        return nil
    }

    private func isWholeDayFoodDelete(_ userMessage: String) -> Bool {
        let patterns = [
            #"(?i)^\s*(?:delete|remove|clear|empty|wipe)\s+(?:all\s+)?(?:my\s+|the\s+)?(?:foods?|meals?|entries?|food\s+log|log)\s*(?:from|for)?\s*(?:today|the\s+day)?\s*$"#,
            #"(?i)^\s*(?:delete|remove|clear|empty|wipe)\s+(?:everything|all)\s*(?:from|for)?\s*(?:today|the\s+day)?\s*$"#,
            #"(?i)^\s*(?:delete|remove|clear)\s+the\s+rest\s*$"#
        ]
        return patterns.contains { userMessage.range(of: $0, options: .regularExpression) != nil }
    }

    private func handleImplicitFoodIdentityCorrection(
        userMessage: String,
        provider: any LLMProvider,
        dayEntries: [FoodEntry],
        recentEntries: [FoodEntry],
        customFoods: [CustomFood]
    ) async -> LoggingResult? {
        guard looksLikeImplicitFoodIdentityCorrection(userMessage),
              let parse = fastParseFoodLog(userMessage),
              parse.mentions.count == 1,
              let mention = parse.mentions.first,
              let target = implicitCorrectionTarget(for: mention.text, in: dayEntries) else {
            return nil
        }

        let initialServings: ServingsInfo
        if mention.servingsInfo.hasExplicitPortion {
            initialServings = mention.servingsInfo
        } else {
            initialServings = ServingsInfo(
                servings: max(0.1, target.servings),
                portionDescription: target.portionDescription.isEmpty ? "1 serving" : target.portionDescription,
                servingUnit: target.servingUnit.isEmpty ? "serving" : target.servingUnit,
                confident: true,
                hasExplicitPortion: true
            )
        }

        guard let resolution = await resolveLoggedCandidate(
            mention: mention.text,
            userMessage: userMessage,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods,
            initialServingsInfo: initialServings
        ) else {
            return nil
        }

        let candidateIdentity = normalizedForComparison("\(resolution.candidate.brand ?? "") \(resolution.candidate.name)")
        let targetIdentity = normalizedForComparison("\(target.brand ?? "") \(target.name)")
        guard candidateIdentity != targetIdentity else { return nil }

        guard let replacementEntry = await loggedEntry(
            for: resolution.candidate,
            mention: mention.text,
            userMessage: userMessage,
            meal: target.meal,
            servingsInfo: resolution.servingsInfo,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods
        ) else {
            return nil
        }

        return LoggingResult(
            action: .replaceEntryById(deleteId: target.id, newEntries: [replacementEntry]),
            reply: "✓ Updated \(target.name) to \(replacementEntry.name)"
        )
    }

    private func looksLikeImplicitFoodIdentityCorrection(_ userMessage: String) -> Bool {
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = [
            "it was ", "that was ", "this was ",
            "actually it was ", "actually that was ", "no it was ", "no that was "
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private func implicitCorrectionTarget(for mention: String, in dayEntries: [FoodEntry]) -> FoodEntry? {
        let mentionIdentity = normalizedForComparison(mention)
        let mentionTokens = Set(identityTokens(in: mention).map(singularized))
        guard !mentionTokens.isEmpty else { return nil }

        let sortedEntries = dayEntries.sorted { $0.date > $1.date }
        if let overlapping = sortedEntries.first(where: { entry in
                let entryIdentity = normalizedForComparison("\(entry.brand ?? "") \(entry.name)")
                if entryIdentity == mentionIdentity { return false }
                let entryTokens = Set(identityTokens(in: "\(entry.brand ?? "") \(entry.name)").map(singularized))
                return !entryTokens.intersection(mentionTokens).isEmpty
        }) {
            return overlapping
        }

        return sortedEntries.first
    }

    private func shouldFastRouteFoodLog(
        _ userMessage: String,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood]
    ) async -> Bool {
        let lowered = userMessage.lowercased()
        let tokens = Set(tokenize(userMessage).map(singularized))
        let blockedTokens: Set<String> = [
            "delete", "remove", "change", "replace", "update", "edit", "undo",
            "goal", "macro", "calorie", "protein", "carb", "fat", "weight", "weigh",
            "water", "hydrate", "hydration"
        ]

        if userMessage.contains("?") || !tokens.intersection(blockedTokens).isEmpty {
            return false
        }
        if lowered.hasPrefix("how ") || lowered.hasPrefix("what ") || lowered.hasPrefix("when ") || lowered.hasPrefix("why ") {
            return false
        }
        if containsBareAndFoodJoiner(userMessage) {
            return false
        }

        guard let parse = fastParseFoodLog(userMessage), !parse.mentions.isEmpty else {
            return false
        }

        for mention in parse.mentions {
            let candidates = await searchCandidates(
                query: mention.text,
                recentEntries: recentEntries,
                customFoods: customFoods
            )
            guard let candidate = candidates.first,
                  isStrongFoodIdentityMatch(candidate, mention: mention.text)
                    || isLowScoreEverydayDefault(candidate, mention: mention.text) else {
                return false
            }
        }

        return true
    }

    private func containsBareAndFoodJoiner(_ text: String) -> Bool {
        text.range(of: #"(?i)(?<![,;])\s+and\s+"#, options: .regularExpression) != nil
    }

    // MARK: - Log Food (focused pipeline)

    private func handleLogFood(
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood]
    ) async -> LoggingResult {

        let fastParse = fastParseFoodLog(userMessage)
        let usedFastParse = fastParse?.mentions.isEmpty == false
        let foodMentions: [FastFoodMention]
        if usedFastParse, let fastParse {
            foodMentions = fastParse.mentions
        } else {
            do {
                foodMentions = try await provider.splitFoods(userMessage: userMessage).map {
                    FastFoodMention(
                        text: $0,
                        servingsInfo: ServingsInfo(
                            servings: 1,
                            portionDescription: "1 serving",
                            servingUnit: "serving",
                            confident: false,
                            hasExplicitPortion: false
                        )
                    )
                }
            } catch {
                return handleProviderError(error)
            }
        }

        let meal: String
        if let parsedMeal = fastParse?.meal {
            meal = parsedMeal
        } else {
            do {
                meal = try await provider.extractMeal(userMessage: userMessage) ?? "snack"
            } catch {
                meal = "snack"
            }
        }

        var entries: [FoodEntry] = []
        var confirmLines: [String] = []

        for parsedMention in foodMentions {
            let mention = parsedMention.text
            let initialServings: ServingsInfo
            if usedFastParse || parsedMention.servingsInfo.confident || parsedMention.servingsInfo.hasExplicitPortion {
                initialServings = parsedMention.servingsInfo
            } else {
                initialServings = await initialServingsInfo(
                    for: mention,
                    userMessage: userMessage,
                    provider: provider
                )
            }

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

    private func fastParseFoodLog(_ userMessage: String) -> FastFoodParse? {
        guard !requiresSemanticFoodSplit(userMessage) else { return nil }

        let meal = fastMeal(in: userMessage)
        var text = userMessage
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: ".", with: ",")
        text = removeLeadingLogLanguage(text)

        let parts = splitFoodMentionText(text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && meaningfulTokens(in: $0).contains { !mealWords.contains($0) } }

        let mentions = parts.map {
            FastFoodMention(text: $0, servingsInfo: fastServingsInfo(for: $0))
        }

        guard !mentions.isEmpty else { return nil }
        return FastFoodParse(meal: meal, mentions: mentions)
    }

    private func requiresSemanticFoodSplit(_ text: String) -> Bool {
        if containsBareAndFoodJoiner(text) {
            return true
        }
        let pattern = #"(?i)\b(?:with\s+(?:a\s+)?side\s+of|served\s+with|along\s+with|alongside|plus)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func fastMeal(in text: String) -> String? {
        for meal in ["breakfast", "lunch", "dinner", "snack"] {
            let patterns = [
                #"(?i)^\s*(?:log\s+)?\#(meal)\s*[:,-]"#,
                #"(?i)^\s*(?:for\s+)?\#(meal)\s+(?:i\s+)?(?:had|ate|drank|was)\b"#,
                #"(?i)\b(?:for|at|during)\s+\#(meal)\b"#,
                #"(?i)\b(?:my\s+)?\#(meal)\s+(?:was|is|included|had)\b"#,
                #"(?i)\bas\s+(?:a\s+)?\#(meal)\b"#
            ]
            if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
                return meal
            }
        }
        return nil
    }

    private func removeLeadingLogLanguage(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^log\s+(breakfast|lunch|dinner|snack)\s*[:,-]\s*"#,
            #"(?i)^log\s+"#,
            #"(?i)^for\s+(breakfast|lunch|dinner|snack)\s+i\s+(had|ate|drank)\s+"#,
            #"(?i)^for\s+(breakfast|lunch|dinner|snack)\s+"#,
            #"(?i)^(breakfast|lunch|dinner|snack)\s*[:,-]\s*"#,
            #"(?i)^(breakfast|lunch|dinner|snack)\s+(was|is|included)\s+"#,
            #"(?i)^i\s+(had|ate|drank)\s+"#,
            #"(?i)^also\s+(had|ate|drank)\s+"#,
            #"(?i)^(had|ate|drank)\s+"#
        ]
        for pattern in patterns {
            trimmed = trimmed.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return trimmed
    }

    private func splitFoodMentionText(_ text: String) -> [String] {
        var normalized = text
        normalized = normalized.replacingOccurrences(of: #"(?i)\s+also\s+(had|ate|drank)\s+"#, with: ", ", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"(?i),\s+and\s+"#, with: ", ", options: .regularExpression)
        return normalized
            .split(separator: ",")
            .map(String.init)
            .map(removeLeadingLogLanguage)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func fastServingsInfo(for mention: String) -> ServingsInfo {
        let tokens = tokenize(mention)
        let count = leadingCount(in: tokens)
        let lowered = mention.lowercased()

        if let count {
            let unit = servingUnitNearCount(tokens: tokens) ?? inferredServingUnit(from: mention)
            let description = "\(count.display) \(pluralized(unit, count: count.value))"
            return ServingsInfo(
                servings: count.value,
                portionDescription: description,
                servingUnit: unit,
                confident: true,
                hasExplicitPortion: true
            )
        }

        if tokens.first == "some" {
            if lowered.contains("spinach") || lowered.contains("blueberr") {
                return ServingsInfo(
                    servings: 1,
                    portionDescription: "1 cup",
                    servingUnit: "cup",
                    confident: true,
                    hasExplicitPortion: false
                )
            }
        }

        return ServingsInfo(
            servings: 1,
            portionDescription: "1 serving",
            servingUnit: "serving",
            confident: false,
            hasExplicitPortion: false
        )
    }

    private func leadingCount(in tokens: [String]) -> (value: Double, display: String)? {
        guard !tokens.isEmpty else { return nil }
        let countToken: String
        if tokens[0] == "about", tokens.indices.contains(1) {
            countToken = tokens[1]
        } else {
            countToken = tokens[0]
        }

        if let number = Double(countToken) {
            return (number, number.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(number))" : "\(number)")
        }

        let words: [String: Double] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "half": 0.5
        ]
        if let value = words[countToken] {
            return (value, value == 0.5 ? "1/2" : "\(Int(value))")
        }
        return nil
    }

    private func requestedCount(in text: String) -> Double? {
        let words: [String: Double] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "couple": 2, "pair": 2
        ]
        for token in tokenize(text) {
            if let number = Double(token) {
                return number
            }
            if let number = words[token] {
                return number
            }
        }
        return nil
    }

    private func servingUnitNearCount(tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        let start = tokens.first == "about" ? 2 : 1
        guard tokens.indices.contains(start) else { return nil }
        let token = singularized(tokens[start])
        switch token {
        case "nugget", "fry", "egg", "slice", "piece", "cup", "bowl", "serving":
            return token
        default:
            return nil
        }
    }

    private func inferredServingUnit(from mention: String) -> String {
        let tokens = Set(tokenize(mention).map(singularized))
        if tokens.contains("nugget") { return "nugget" }
        if tokens.contains("fry") { return "fry" }
        if tokens.contains("egg") { return "egg" }
        if tokens.contains("slice") { return "slice" }
        if tokens.contains("piece") { return "piece" }
        if tokens.contains("cup") { return "cup" }
        return "serving"
    }

    private func pluralized(_ unit: String, count: Double) -> String {
        guard abs(count - 1) > 0.0001 else { return unit }
        if unit == "fry" { return "fries" }
        return unit + "s"
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
        let serverAttempt = await serverResolveLoggedCandidate(
            mention: mention,
            userMessage: userMessage,
            provider: provider,
            recentEntries: recentEntries,
            customFoods: customFoods,
            initialServingsInfo: initialServingsInfo
        )
        switch serverAttempt {
        case .resolved(let resolution):
            return resolution
        case .noMatch:
            return nil
        case .unavailable:
            break
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

        let brandMatched = brandMatchesMention(candidate.brand, mention: mention)
        if candidate.portionBasis == .fixedServing,
           brandMatched,
           initialServingsInfo.hasExplicitPortion,
           let adjusted = adjustedFixedServingInfo(candidate: candidate, servingsInfo: initialServingsInfo) {
            return CandidateResolution(candidate: candidate, servingsInfo: adjusted)
        }

        if candidate.portionBasis == .grams,
           isStrongFoodIdentityMatch(candidate, mention: mention),
           candidate.score >= 36 || isLowScoreEverydayDefault(candidate, mention: mention) {
            return CandidateResolution(
                candidate: candidate,
                servingsInfo: initialServingsInfo
            )
        }
        return nil
    }

    private func isStrongFoodIdentityMatch(_ candidate: SearchCandidate, mention: String) -> Bool {
        let mentionTokens = Set(identityTokens(in: mention).map(singularized))
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))
        let mentionsChickFilA = mentionTokens.contains("chick") && mentionTokens.contains("fil")

        if mentionsChickFilA,
           mentionTokens.contains("nugget"),
           candidateTokens.contains("chicken"),
           candidateTokens.contains("nugget") {
            return true
        }

        if mentionsChickFilA,
           mentionTokens.contains("fry"),
           candidateTokens.contains("waffle"),
           candidateTokens.contains("fry") {
            return true
        }

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

        if mentionTokens.contains("coffee"),
           candidateTokens.contains("coffee") {
            return true
        }

        let meaningfulMentionTokens = mentionTokens.filter { !["chick", "fil"].contains($0) }
        guard !meaningfulMentionTokens.isEmpty else { return false }
        let matched = meaningfulMentionTokens.filter { mentionToken in
            candidateTokens.contains(mentionToken)
                || candidateTokens.contains(where: { editDistanceLimited(mentionToken, $0, maxDistance: 1) <= 1 })
        }
        return Double(matched.count) / Double(meaningfulMentionTokens.count) >= 0.75
    }

    private func isLowScoreEverydayDefault(_ candidate: SearchCandidate, mention: String) -> Bool {
        let mentionTokens = Set(identityTokens(in: mention).map(singularized))
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))
        return mentionTokens == ["coffee"]
            && candidateTokens.contains("coffee")
            && candidateTokens.contains("black")
    }

    private func isPlainCoffeeQuery(_ query: String) -> Bool {
        Set(identityTokens(in: query).map(singularized)) == ["coffee"]
    }

    private func isAmbiguousPlainCoffeeCandidate(_ candidate: SearchCandidate) -> Bool {
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))
        guard candidateTokens == ["coffee"] else { return false }
        if candidate.source == .recent, candidate.caloriesPerServing > 25 {
            return true
        }
        if let density = calorieDensity(for: candidate), density > 20 {
            return true
        }
        return false
    }

    private func brandMatchesMention(_ brand: String?, mention: String) -> Bool {
        guard let brand, !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let brandTokens = Set(tokenize(brand).filter { $0 != "a" }.map(singularized))
        let mentionTokens = Set(tokenize(mention).filter { $0 != "a" }.map(singularized))
        return !brandTokens.isEmpty && brandTokens.isSubset(of: mentionTokens)
    }

    private func adjustedFixedServingInfo(candidate: SearchCandidate, servingsInfo: ServingsInfo) -> ServingsInfo? {
        guard servingsInfo.servings > 0,
              let count = countRepresentedByFixedServing(candidate: candidate, unit: servingsInfo.servingUnit),
              count > 0 else {
            return nil
        }

        return ServingsInfo(
            servings: max(0.1, servingsInfo.servings / count),
            portionDescription: servingsInfo.portionDescription,
            servingUnit: servingsInfo.servingUnit,
            confident: servingsInfo.confident,
            hasExplicitPortion: servingsInfo.hasExplicitPortion
        )
    }

    private func countRepresentedByFixedServing(candidate: SearchCandidate, unit: String) -> Double? {
        let singularUnit = singularized(unit.lowercased())
        guard ["nugget", "piece", "strip", "slice"].contains(singularUnit) else { return nil }
        let text = "\(candidate.name) \(candidate.servingDesc ?? "")"
        let tokens = tokenize(text)
        for index in tokens.indices.dropLast() {
            guard let value = Double(tokens[index]), value > 0 else { continue }
            let end = min(tokens.count, index + 6)
            let following = tokens[(index + 1)..<end].map(singularized)
            if following.contains(singularUnit) {
                return value
            }
        }
        return nil
    }

    private func serverResolveLoggedCandidate(
        mention: String,
        userMessage: String,
        provider: any LLMProvider,
        recentEntries: [FoodEntry],
        customFoods: [CustomFood],
        initialServingsInfo: ServingsInfo
    ) async -> ServerResolutionAttempt {
        let resolved: ResolvedFoodCandidate
        do {
            resolved = try await provider.resolveFoodCandidate(
                userMessage: userMessage,
                foodMention: mention
            )
        } catch let error as ResolveFoodCandidateError where error == .unsupported {
            return .unavailable
        } catch let error as ResolveFoodCandidateError where error == .noMatch {
            return .noMatch
        } catch {
            return .unavailable
        }

        guard let candidate = await resolveCandidate(
            candidateId: resolved.candidateId,
            recentEntries: recentEntries,
            customFoods: customFoods
        ) else {
            return .unavailable
        }

        let localName = normalizedForComparison(candidate.name)
        let remoteName = normalizedForComparison(resolved.name)
        guard !localName.isEmpty, localName == remoteName else {
            return .unavailable
        }

        let localBrand = normalizedForComparison(candidate.brand ?? "")
        let remoteBrand = normalizedForComparison(resolved.brand ?? "")
        if !localBrand.isEmpty || !remoteBrand.isEmpty, localBrand != remoteBrand {
            return .unavailable
        }

        return .resolved(CandidateResolution(
            candidate: candidate,
            servingsInfo: ServingsInfo(
                servings: max(0.1, resolved.servings),
                portionDescription: resolved.portionDescription.isEmpty ? initialServingsInfo.portionDescription : resolved.portionDescription,
                servingUnit: resolvedServingUnit(resolved.servingUnit),
                confident: resolved.confident,
                hasExplicitPortion: resolved.hasExplicitPortion || initialServingsInfo.hasExplicitPortion
            )
        ))
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

    private func deterministicGrams(for candidate: SearchCandidate, servingsInfo: ServingsInfo) -> Double? {
        if let explicitGrams = gramsMentioned(in: servingsInfo.portionDescription) {
            return max(explicitGrams, 1)
        }

        if servingsInfo.hasExplicitPortion,
           let servingGrams = candidate.servingGrams,
           let representedCount = countRepresentedByServingDescription(candidate.servingDesc, unit: servingsInfo.servingUnit),
           representedCount > 0 {
            return max(servingGrams / representedCount * servingsInfo.servings, 1)
        }

        if servingsInfo.hasExplicitPortion,
           let approximate = approximateUnitGrams(unit: servingsInfo.servingUnit, foodName: candidate.name) {
            return max(approximate * servingsInfo.servings, 1)
        }

        if let servingGrams = candidate.servingGrams, servingGrams > 0 {
            return servingGrams
        }

        return nil
    }

    private func gramsMentioned(in text: String) -> Double? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(g|gram|grams)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    private func countRepresentedByServingDescription(_ servingDescription: String?, unit: String) -> Double? {
        guard let servingDescription else { return nil }
        let singularUnit = singularized(unit.lowercased())
        let tokens = tokenize(servingDescription)
        for index in tokens.indices.dropLast() {
            guard let value = Double(tokens[index]), value > 0 else { continue }
            let next = singularized(tokens[index + 1])
            if next == singularUnit || (singularUnit == "nugget" && next == "piece") || (singularUnit == "fry" && next == "piece") {
                return value
            }
        }
        if tokens.contains("1"), tokens.contains(singularUnit) {
            return 1
        }
        return nil
    }

    private func approximateUnitGrams(unit: String, foodName: String) -> Double? {
        let singularUnit = singularized(unit.lowercased())
        let foodTokens = Set(meaningfulTokens(in: foodName).map(singularized))
        switch singularUnit {
        case "egg":
            return 50
        case "nugget":
            return 16
        case "fry":
            return foodTokens.contains("waffle") ? 5 : 4
        case "cup":
            if foodTokens.contains("spinach") { return 30 }
            if foodTokens.contains("blueberry") { return 148 }
            if foodTokens.contains("coffee") { return 240 }
            return nil
        default:
            return nil
        }
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
            if let deterministic = deterministicGrams(for: candidate, servingsInfo: servingsInfo) {
                grams = deterministic
            } else {
                grams = await estimateGrams(
                    for: candidate,
                    portionDescription: servingsInfo.portionDescription,
                    provider: provider,
                    referenceServingDescription: candidate.servingDesc,
                    referenceServingGrams: candidate.servingGrams
                )
            }
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
        let queryTokens = Set(identityTokens(in: query).map(singularized))
        let candidateTokens = Set(meaningfulTokens(in: candidate.name).map(singularized))
        let brandTokens = Set(meaningfulTokens(in: candidate.brand ?? "").map(singularized))
        let hasUnstatedMenuSize = candidateTokens.contains { menuSizeWords.contains($0) }
            && !queryTokens.contains { menuSizeWords.contains($0) }
        var score = 0

        if name == normalizedQuery {
            score += 80
        } else if !normalizedQuery.isEmpty && name.hasPrefix(normalizedQuery + " ") {
            score += 45
        }

        let overlap = queryOverlapScore(query: query, candidateName: candidate.name, brand: candidate.brand)
        score += overlap * 12

        let fuzzyOverlap = fuzzyQueryOverlapScore(queryTokens: queryTokens, candidateTokens: candidateTokens.union(brandTokens))
        score += fuzzyOverlap * 30

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

        if queryTokens.contains("coffee"), candidateTokens.contains("coffee") {
            if candidateTokens.contains("black") {
                score += 60
            }
            for bad in ["candy", "honey", "nut", "cashew"] where candidateTokens.contains(bad) && !queryTokens.contains(bad) {
                score -= 50
            }
        }

        if isPlainCoffeeQuery(query), isAmbiguousPlainCoffeeCandidate(candidate) {
            score -= 220
        }

        let mentionsChickFilA = queryTokens.contains("chick") && queryTokens.contains("fil")
        if mentionsChickFilA,
           let brand = candidate.brand,
           brandMatchesMention(brand, mention: query) {
            let foodTokens = queryTokens.subtracting(brandTokens)
            let foodTokenMatched = foodTokens.isEmpty || foodTokens.contains { token in
                candidateTokens.contains(token)
                    || candidateTokens.contains(where: { editDistanceLimited(token, $0, maxDistance: 1) <= 1 })
            }
            if foodTokenMatched {
                score += (hasUnstatedMenuSize && countBased) ? 70 : 500
            } else {
                score -= 250
            }
        }

        if mentionsChickFilA,
           queryTokens.contains("nugget"),
           candidateTokens.contains("chicken"),
           candidateTokens.contains("nugget") {
            score += candidate.portionBasis == .grams ? 70 : 32
        }

        if mentionsChickFilA,
           queryTokens.contains("fry"),
           candidateTokens.contains("waffle"),
           candidateTokens.contains("fry") {
            score += candidate.portionBasis == .grams ? 70 : 20
        }

        if countBased,
           (candidate.servingDesc ?? "").lowercased().contains("100g") {
            score -= 36
        }

        if countBased, let servingGrams = candidate.servingGrams {
            if servingGrams < 15 {
                score -= 28
            } else if servingGrams >= 40 {
                score += 8
            }
        }

        if countBased, candidate.portionBasis == .fixedServing {
            let requestedUnit = inferredServingUnit(from: query)
            if let representedCount = countRepresentedByFixedServing(candidate: candidate, unit: requestedUnit) {
                score += 140
                if let requestedCount = requestedCount(in: query) {
                    score -= min(Int(abs(representedCount - requestedCount) * 16), 160)
                }
            } else {
                score -= 180
            }
        }

        if countBased, hasUnstatedMenuSize, candidate.portionBasis == .fixedServing {
            score -= 320
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

    private func fuzzyQueryOverlapScore(queryTokens: Set<String>, candidateTokens: Set<String>) -> Int {
        queryTokens.reduce(0) { total, queryToken in
            if candidateTokens.contains(queryToken) {
                return total
            }
            let matched = candidateTokens.contains { candidateToken in
                editDistanceLimited(queryToken, candidateToken, maxDistance: 1) <= 1
            }
            return total + (matched ? 1 : 0)
        }
    }

    private func editDistanceLimited(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        if lhs == rhs { return 0 }
        if abs(lhs.count - rhs.count) > maxDistance { return maxDistance + 1 }
        if lhs.isEmpty || rhs.isEmpty { return max(lhs.count, rhs.count) }

        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                let insertion = current[j - 1] + 1
                let deletion = previous[j] + 1
                current[j] = min(substitution, insertion, deletion)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maxDistance {
                return maxDistance + 1
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private func extraConceptTokens(in candidateName: String, comparedTo query: String) -> [String] {
        let queryTokens = Set(identityTokens(in: query).map(singularized))
        let candidateTokens = meaningfulTokens(in: candidateName).map(singularized)
        return candidateTokens.filter { token in
            guard !wholeFoodNeutralWords.contains(token), !queryTokens.contains(token) else { return false }
            return !queryTokens.contains { queryToken in
                token.count >= 4
                    && queryToken.count >= 4
                    && editDistanceLimited(token, queryToken, maxDistance: 1) <= 1
            }
        }
    }

    private func isLiteralWholeFoodMatch(_ candidate: SearchCandidate, query: String) -> Bool {
        guard looksLikePlainWholeFoodQuery(query) else { return false }
        if isPlainCoffeeQuery(query), isAmbiguousPlainCoffeeCandidate(candidate) {
            return false
        }
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
        if isPlainCoffeeQuery(query), isAmbiguousPlainCoffeeCandidate(candidate) {
            return false
        }
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

        if coreTokens.count >= 2 {
            for index in coreTokens.indices {
                let reduced = coreTokens.enumerated().compactMap { $0.offset == index ? nil : $0.element }
                if !reduced.isEmpty {
                    variants.append(reduced.joined(separator: " "))
                }
            }
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

        let mentionsChickFilA = singularTokens.contains("chick") && singularTokens.contains("fil")
        let mentionsChicken = singularTokens.contains("chicken") || mentionsChickFilA
        let mentionsNuggets = singularTokens.contains("nugget")
        let mentionsFries = singularTokens.contains("fry") || singularTokens.contains("frie")
        let mentionsWaffle = singularTokens.contains("waffle") || mentionsChickFilA

        if mentionsNuggets, mentionsChicken {
            variants.append("chicken nuggets")
        } else if mentionsNuggets, tokens.count == 1 {
            variants.append("chicken nuggets")
        }

        if mentionsFries, mentionsWaffle {
            variants.append("waffle fries")
        } else if mentionsFries, tokens.count <= 2 {
            variants.append("french fries")
        }

        if singularTokens.contains("egg") {
            variants.append("whole egg")
        }

        if singularTokens.contains("spinach") {
            variants.append("spinach raw")
        }

        if singularTokens.contains("coffee") {
            variants.append("black coffee")
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
