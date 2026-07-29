import Foundation
import FoundationModels

// MARK: - Legacy Generable types (general-purpose)
//
// These back the existing `complete()` path, which returns one JSON string.
// The NEW focused methods below use their own tiny @Generable structs — one
// per step — because on-device models produce far better output when asked
// a single question with a tight schema.

@available(iOS 26, *)
@Generable
struct GeneratedSearchQuery: Hashable {
    @Guide(description: "Search term for the food database, 1-3 words")
    var q: String
    @Guide(description: "What the user said they ate, like '2 slices of bacon'")
    var description: String
    @Guide(description: "Meal: breakfast, lunch, dinner, or snack")
    var meal: String
}

@available(iOS 26, *)
@Generable
struct GeneratedFoodItem: Hashable {
    @Guide(description: "Concise food identity for search, like 'bacon' or 'banana pancake'")
    var foodName: String?
    @Guide(description: "Optional search query for this food item")
    var searchQuery: String?
    @Guide(description: "The candidate_id string from the search results. Use this to identify which food to log.")
    var candidateId: String?
    @Guide(description: "The fdc_id integer from the database search results, if shown.")
    var fdcId: Int?
    @Guide(description: "Portion description like '2 slices' or '1 large egg'")
    var portionDescription: String
    @Guide(description: "Number of servings as a decimal number")
    var servings: Double
    @Guide(description: "Meal: breakfast, lunch, dinner, or snack")
    var meal: String
}

@available(iOS 26, *)
@Generable
struct GeneratedResponse {
    @Guide(description: "The action to perform. Must be one of: log_food, search_foods, reply, ask_clarification, edit_entry, delete_entry, delete_meal, replace_entry, log_weight, set_goal, query_log, query_weight")
    var action: String

    @Guide(description: "A follow-up question to ask the user when you need more information")
    var question: String?

    @Guide(description: "Text answer when action is reply — answer the user's question or ask for clarification")
    var text: String?

    @Guide(description: "Search queries when action is search")
    var queries: [GeneratedSearchQuery]?

    @Guide(description: "Food items to log, each with an fdc_id from the database results")
    var items: [GeneratedFoodItem]?

    @Guide(description: "Exact food name from the user's log for edit, delete, or replace")
    var foodName: String?

    @Guide(description: "Array of exact food names to delete in bulk")
    var foodNames: [String]?

    @Guide(description: "Meal name to clear: breakfast, lunch, dinner, or snack")
    var meal: String?

    @Guide(description: "Body weight in pounds")
    var weightLbs: Double?

    @Guide(description: "New portion weight in grams for edit_entry")
    var newPortionGrams: Double?
    @Guide(description: "New portion description for edit_entry like '1 cup' or '2 slices'")
    var newPortionDescription: String?

    @Guide(description: "Dates to look up: 'today', 'yesterday', 'last_7_days', 'last_30_days', or 'YYYY-MM-DD'")
    var dates: [String]?

    @Guide(description: "New calorie goal")
    var goalCalories: Double?
    @Guide(description: "New protein goal in grams")
    var goalProtein: Double?
    @Guide(description: "New carbs goal in grams")
    var goalCarbs: Double?
    @Guide(description: "New fat goal in grams")
    var goalFat: Double?
    @Guide(description: "New fiber goal in grams")
    var goalFiber: Double?
}

// MARK: - Focused Generable types (one per step)

/// Constrains the model's intent output to one of the seven valid cases.
/// Using an enum (rather than `var intent: String`) means the model is
/// structurally prevented from emitting "log food", "adding food",
/// "food_log" or any other variant — Foundation Models will only generate
/// one of the listed cases.
@available(iOS 26, *)
@Generable
enum IntentCategory: String {
    case logFood      = "log_food"
    case deleteFood   = "delete_food"
    case editFood     = "edit_food"
    case moveFood     = "move_food"
    case queryData    = "query_data"
    case logWeight    = "log_weight"
    case logWater     = "log_water"
    case setGoal      = "set_goal"
    case reply        = "reply"
}

@available(iOS 26, *)
@Generable
struct IntentPick {
    @Guide(description: "The category this message falls into.")
    var intent: IntentCategory
}

@available(iOS 26, *)
@Generable
struct FoodSplit {
    @Guide(description: "Each distinct food the user mentioned, as a short phrase. Example: for 'eggs and toast' return [\"eggs\",\"toast\"]. For 'peanut butter and jelly sandwich' return [\"peanut butter and jelly sandwich\"].")
    var foods: [String]
}

@available(iOS 26, *)
@Generable
struct SearchQueryPick {
    @Guide(description: "Short database search query, usually 1-4 words.")
    var query: String
}

@available(iOS 26, *)
@Generable
struct CandidateIndexPick {
    @Guide(description: "Zero-based index of the best candidate, or -1 if none fit.")
    var candidateIndex: Int
}

@available(iOS 26, *)
@Generable
struct CandidateValidationPick {
    @Guide(description: "True when the currently selected candidate is a realistic nutrition basis for what the user said they ate.")
    var keepCurrentCandidate: Bool
    @Guide(description: "Final serving count after reconciling the food mention with the extracted portion.")
    var servings: Double
    @Guide(description: "Final human-readable portion description such as '3 pieces' or '1/2 cup'.")
    var portionDescription: String
    @Guide(description: "Reusable base unit for this portion, singular when natural, such as 'piece', 'slice', 'cup', or 'serving'.")
    var servingUnit: String
    @Guide(description: "True if the final amount is explicit and trustworthy.")
    var confident: Bool
    @Guide(description: "True only when the user explicitly provided a usable amount, size, count, or fraction.")
    var hasExplicitPortion: Bool
    @Guide(description: "A neutral scalable replacement search query for the underlying food when the current candidate should not be kept. Empty string if not needed.")
    var replacementSearchQuery: String
}

@available(iOS 26, *)
@Generable
struct MatchConfirm {
    @Guide(description: "True if the candidate is a reasonable match for what the user said. False if it's clearly wrong.")
    var isMatch: Bool
}

@available(iOS 26, *)
@Generable
struct ServingsPick {
    @Guide(description: "Number of servings as a decimal, e.g. 2.0 for '2 slices', 1.0 if unstated.")
    var servings: Double
    @Guide(description: "Portion description using the user's own words, e.g. '2 slices', '1 cup', '3 oz'. If user said nothing, use '1 serving'.")
    var portionDescription: String
    @Guide(description: "Reusable base unit for this portion, singular when natural, such as 'slice', 'cup', 'piece', or 'serving'.")
    var servingUnit: String
    @Guide(description: "True if the user clearly stated an amount, false if you had to guess.")
    var confident: Bool
    @Guide(description: "True only when the user explicitly provided a usable amount, size, count, or fraction for this message. False for vague objections like 'that's not right'.")
    var hasExplicitPortion: Bool
}

@available(iOS 26, *)
@Generable
struct MealPick {
    @Guide(description: "Exactly one of: breakfast, lunch, dinner, snack, or none if the user gave no hint.")
    var meal: String
}

@available(iOS 26, *)
@Generable
struct WaterMutationPick {
    @Guide(description: "Exactly one of: add, delete_all, update_total, reply.")
    var action: String
    @Guide(description: "Water amount in fluid ounces for add or update_total. Use null-ish 0 only when no amount was provided.")
    var amountOz: Double
}

@available(iOS 26, *)
@Generable
struct WeightMutationPick {
    @Guide(description: "Exactly one of: add, update, delete, delete_all, reply.")
    var action: String
    @Guide(description: "Body weight in pounds for add/update. Use 0 when absent.")
    var weightLbs: Double
    @Guide(description: "Date hint: today, yesterday, latest, or empty when unspecified.")
    var dateHint: String
}

@available(iOS 26, *)
@Generable
struct DeletePick {
    @Guide(description: "Exact food names from the log the user wants to delete. Use the names exactly as they appear in the provided log.")
    var foodNames: [String]
}

@available(iOS 26, *)
@Generable
struct EditTargetPick {
    @Guide(description: "Exact food name from the provided log to edit. Empty string if unclear.")
    var foodName: String
    @Guide(description: "A short follow-up question when the target is unclear. Empty string if not needed.")
    var clarificationQuestion: String
}

@available(iOS 26, *)
@Generable
struct EditResolutionPick {
    @Guide(description: "Number of servings represented by the corrected amount.")
    var servings: Double
    @Guide(description: "User-facing portion description for the corrected amount.")
    var portionDescription: String
    @Guide(description: "Reusable base unit for this portion, singular when natural, such as 'piece', 'slice', 'cup', or 'serving'.")
    var servingUnit: String
    @Guide(description: "True if the user clearly stated a replacement amount.")
    var confident: Bool
    @Guide(description: "False when the user only objected or was too vague to edit yet.")
    var hasExplicitPortion: Bool
    @Guide(description: "Short follow-up question when the amount is unclear. Empty string if not needed.")
    var clarificationQuestion: String
    @Guide(description: "Neutral replacement search query when the current item is too specific to resize directly. Empty string if direct resizing is fine.")
    var replacementSearchQuery: String
}

@available(iOS 26, *)
@Generable
struct GramsEstimate {
    @Guide(description: "Total estimated grams for this portion based on real-world knowledge. For example: 2 slices of bacon ≈ 24 g, 1 cup of milk ≈ 244 g, 1 large egg ≈ 50 g.")
    var grams: Double
}

@available(iOS 26, *)
@Generable
struct ReplyText {
    @Guide(description: "A friendly, concise reply (1-3 sentences) answering the user's question using the provided context.")
    var text: String
}

// MARK: - Apple Foundation Models Provider

/// Uses Apple's on-device LanguageModelSession (requires iOS 26 + Apple Intelligence).
/// Each focused method uses its own tiny @Generable struct — the model can only
/// fill in the fields that exist, which eliminates hallucinated goal_calories /
/// weight_lbs / etc. noise.
struct FoundationModelsProvider: LLMProvider {

    // MARK: - Legacy complete() (general-purpose JSON)

    func complete(
        systemPrompt: String,
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> LLMCompletion {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let (instructions, enrichedUserMessage) = split(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            recentMessages: recentMessages
        )

        return try await generateGeneric(
            instructions: instructions,
            userMessage: enrichedUserMessage
        )
    }

    // MARK: - Focused methods

    func classifyIntent(
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> UserIntentKind {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        You classify ONE chat message from a food-tracking app.

        log_food  — user says they consumed food or drink. ALWAYS this when the
                    message describes what the user ate/drank/had, with or without
                    a meal name or quantity.
          "I had 2 slices of bacon"           → log_food
          "for lunch I had a turkey sandwich" → log_food
          "ate an apple this morning"         → log_food
          "bacon"                             → log_food
          "3 eggs and toast"                  → log_food
          "coffee with milk"                  → log_food

        delete_food — user wants to remove something from their log.
          "delete the bacon"        → delete_food
          "remove lunch"            → delete_food
          after a recent correction, requests to remove an old/original/previous item → delete_food
          short referential follow-ups such as "both", "all of them", "the other one", "those too", or "them too" after a delete request or a recently logged group → delete_food
          "undo" or "revert" by itself is not delete_food unless the user explicitly says delete, remove, clear, or did not eat

        edit_food — user wants to change a portion they already logged.
          "make the bacon 3 slices" → edit_food
          "that was 1 cup not 2"    → edit_food
          after a recent food log, "that's not right" → edit_food
          after a recent food log, a corrected count or portion → edit_food
          after a recent food log, corrections to food type, ingredient, brand, preparation, caffeine, dairy, meat, or plant-based variant → edit_food
          after a recent food log, vague correction requests like "too much", "undo that", or "make it healthier" → edit_food
          "undo", "revert", or "change back" after recent food logging/editing → edit_food unless the user explicitly asks to delete

        move_food — user wants an existing food assigned to another meal.
          "move the rice from dinner to lunch" → move_food
          "put that yogurt under breakfast" → move_food

        query_data — user asks about their logs, weight, nutrition history, trends, averages, or goals.
          "how many calories today?"                     → query_data
          "show me yesterday"                            → query_data
          "how much did I weigh yesterday?"              → query_data
          "what's my weight trend?"                      → query_data
          "how has my weight changed over 3 months?"     → query_data
          "average calories over the past week"          → query_data
          "what did I eat the most this month?"          �� query_data
          "how much protein have I been getting?"        → query_data
          "am I hitting my goals?"                       → query_data
          "compare this week to last week"               → query_data
          "how much water did I drink today?"            → query_data
          water or hydration amount questions, even when they use contextual words like "after that" → query_data
          "am I staying hydrated?"                       → query_data

        log_weight — user is recording a body-weight measurement.
          "I weigh 180 lbs" → log_weight
          "change today's weight to 181" → log_weight
          "delete yesterday's weight" → log_weight
          "clear all my weights" → log_weight

        log_water — user is logging water or hydration intake, or wants to clear their water log.
          "I drank 16 oz of water"    → log_water
          "log 2 cups of water"       → log_water
          "had a glass of water"      → log_water
          "drank a bottle of water"   → log_water
          "set my water total to 64 oz" → log_water
          "set hydration to 80 ounces"  → log_water
          "clear my water log"        → log_water

        set_goal — user wants to change their calorie or macro target.
          "set my calorie goal to 2000" → set_goal

        reply — ONLY for greetings, small talk, or questions about the app itself.
          "hi"           → reply
          "thanks"       → reply
          "how do I use this app?" → reply

        If the message mentions food the user ate, drank, or had, the answer is
        log_food — never reply.
        If the message is specifically about water/hydration intake, the answer is
        log_water — not log_food.
        """

        let enriched = buildContext(recentMessages: recentMessages) + "User: \(userMessage)"
        let result = try await respond(
            instructions: instructions,
            userMessage: enriched,
            generating: IntentPick.self
        )

        // IntentCategory is @Generable, so the model is already constrained to
        // emit a valid case. We just remap to the app's UserIntentKind.
        switch result.intent {
        case .logFood:    return .logFood
        case .deleteFood: return .deleteFood
        case .editFood:   return .editFood
        case .moveFood:   return .moveFood
        case .queryData:  return .queryData
        case .logWeight:  return .logWeight
        case .logWater:   return .logWater
        case .setGoal:    return .setGoal
        case .reply:      return .reply
        }
    }

    func splitFoods(userMessage: String) async throws -> [String] {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Identify each DISTINCT food or drink the user said they consumed.
        Treat compound foods like "peanut butter and jelly sandwich" or "mac and cheese" as a single food.
        Split "X and Y" or "X, Y" into separate items when they are truly separate foods.
        Split a base food or drink from independently measurable add-ins, toppings, or accompaniments so each can receive its own portion and nutrition.
        For example, "3 cups of coffee with creamer" is "3 cups of coffee" plus "creamer".
        Do not copy a quantity onto an add-in unless the user explicitly gave that add-in its own quantity.
        Keep each item's quantity attached to that item, but remove meal names and conversational wording.
        """

        let result = try await respond(
            instructions: instructions,
            userMessage: "User: \(userMessage)",
            generating: FoodSplit.self
        )

        let cleaned = result.foods
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return cleaned.isEmpty ? [userMessage] : cleaned
    }

    func buildFoodSearchQuery(
        userMessage: String,
        foodMention: String
    ) async throws -> String {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Convert the food mention into the best short database search query.
        The amount in the food mention matters.
        Keep exact restaurant or menu wording only when the user clearly specified that exact size or count and wants that exact menu item.
        If the user gave a loose partial amount of a branded menu item,
        prefer a nutritionally equivalent scalable food over a fixed full-size menu entry.
        """

        let result = try await respond(
            instructions: instructions,
            userMessage: "User said: \(userMessage)\nFood mention: \(foodMention)",
            generating: SearchQueryPick.self
        )

        let query = result.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? foodMention : query
    }

    func chooseFoodCandidate(
        userMessage: String,
        foodMention: String,
        candidates: [FoodChoiceOption]
    ) async throws -> Int? {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Pick the best candidate for the user's food mention.
        Favor candidates whose serving description and specificity fit the user's amount.
        Favor gram-scalable candidates for loose partial amounts when the alternatives are fixed whole servings.
        Reject menu-size candidates when the size or count clearly conflicts with the user's wording.
        Return -1 if none fit.
        """

        let candidateLines = candidates.enumerated().map { index, candidate in
            let brand = candidate.brand?.isEmpty == false ? " | brand: \(candidate.brand!)" : ""
            let serving = candidate.servingDescription?.isEmpty == false ? " | serving: \(candidate.servingDescription!)" : ""
            let source = candidate.source?.isEmpty == false ? " | source: \(candidate.source!)" : ""
            return "\(index): \(candidate.name)\(brand)\(serving)\(source) | basis: \(candidate.portionBasis) | calories: \(Int(candidate.caloriesPerServing.rounded()))"
        }.joined(separator: "\n")

        let result = try await respond(
            instructions: instructions,
            userMessage: "User said: \(userMessage)\nFood mention: \(foodMention)\nCandidates:\n\(candidateLines)",
            generating: CandidateIndexPick.self
        )

        return candidates.indices.contains(result.candidateIndex) ? result.candidateIndex : nil
    }

    func validateFoodCandidate(
        userMessage: String,
        foodMention: String,
        searchQuery: String,
        candidate: FoodChoiceOption,
        servingsInfo: ServingsInfo
    ) async throws -> FoodCandidateValidation {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Review whether the selected nutrition database candidate is a realistic basis for the user's portion.
        The original food mention is the source of truth for the amount.
        If the extracted portion lost an explicit count or size from the food mention, correct it.
        If the selected candidate introduces an unrelated subpart or meal context the user did not mention, reject it and provide a better replacement search query.
        If the user gave a vague amount, convert it into a conservative natural everyday portion when one exists instead of inventing a large fixed menu serving.
        If the candidate is a fixed whole serving or menu item that does not fit the user's small partial amount, reject it and provide a neutral scalable replacement search query.
        Keep restaurant/menu candidates only when the user's amount actually matches that exact item size or count.
        Return a reusable servingUnit in singular form when natural, such as "piece", "slice", "cup", or "serving".
        """

        let brand = candidate.brand?.isEmpty == false ? "\nCandidate brand: \(candidate.brand!)" : ""
        let serving = candidate.servingDescription?.isEmpty == false ? "\nCandidate serving: \(candidate.servingDescription!)" : ""
        let source = candidate.source?.isEmpty == false ? "\nCandidate source: \(candidate.source!)" : ""
        let result = try await respond(
            instructions: instructions,
            userMessage: """
            User said: \(userMessage)
            Food mention: \(foodMention)
            Search query: \(searchQuery)
            Selected candidate: \(candidate.name)\(brand)\(serving)\(source)
            Portion basis: \(candidate.portionBasis)
            Calories per serving: \(Int(candidate.caloriesPerServing.rounded()))
            Extracted portion: \(servingsInfo.portionDescription)
            Extracted servings: \(servingsInfo.servings)
            Extracted serving unit: \(servingsInfo.servingUnit)
            Extracted confident: \(servingsInfo.confident)
            Extracted hasExplicitPortion: \(servingsInfo.hasExplicitPortion)
            """,
            generating: CandidateValidationPick.self
        )

        let replacementQuery = result.replacementSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return FoodCandidateValidation(
            keepCurrentCandidate: result.keepCurrentCandidate,
            servings: max(0.1, result.servings),
            portionDescription: result.portionDescription.isEmpty ? servingsInfo.portionDescription : result.portionDescription,
            servingUnit: result.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? servingsInfo.servingUnit : result.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines),
            confident: result.confident,
            hasExplicitPortion: result.hasExplicitPortion,
            replacementSearchQuery: replacementQuery.isEmpty ? nil : replacementQuery
        )
    }

    func confirmFoodMatch(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateBrand: String?
    ) async throws -> Bool {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Decide if the candidate is a reasonable match for what the user said.
        Be lenient on minor wording differences. Reject if the candidate is clearly a different food
        (e.g. user said "cheese" but candidate is "pork chop").
        """

        let brandText = candidateBrand?.isEmpty == false ? " (\(candidateBrand!))" : ""
        let userPrompt = """
        User said: \(userMessage)
        Food in question: \(foodMention)
        Candidate: \(candidateName)\(brandText)
        """

        let result = try await respond(
            instructions: instructions,
            userMessage: userPrompt,
            generating: MatchConfirm.self
        )

        return result.isMatch
    }

    func extractServings(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateServingDescription: String?
    ) async throws -> ServingsInfo {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Figure out how many servings of the food the user ate, and a short human description.
        Focus only on the named food mention. The amount can appear before or after the food name. Do not borrow quantities from other foods in the same message.
        Do not invent a replacement amount when the user is only objecting or saying the previous amount was wrong.
        Return a reusable servingUnit in singular form when natural, such as "piece", "slice", "cup", or "serving".
        Examples:
        - "2 slices of bacon" → servings: 2, portionDescription: "2 slices", servingUnit: "slice", confident: true, hasExplicitPortion: true
        - "a cup of rice" → servings: 1, portionDescription: "1 cup", servingUnit: "cup", confident: true, hasExplicitPortion: true
        - "half an avocado" → servings: 0.5, portionDescription: "1/2 avocado", servingUnit: "avocado", confident: true, hasExplicitPortion: true
        - in a message containing several foods, use only the quantity grammatically attached to the named food
        - a vague amount → servings: 1, portionDescription: "1 serving", servingUnit: "serving", confident: false, hasExplicitPortion: false
        - "That's not right..." → servings: 1, portionDescription: "1 serving", servingUnit: "serving", confident: false, hasExplicitPortion: false
        """

        let servingText = candidateServingDescription.map { " (default serving: \($0))" } ?? ""
        let userPrompt = """
        User said: \(userMessage)
        Food: \(foodMention) → matched to \(candidateName)\(servingText)
        """

        let result = try await respond(
            instructions: instructions,
            userMessage: userPrompt,
            generating: ServingsPick.self
        )

        return ServingsInfo(
            servings: max(0.1, result.servings),
            portionDescription: result.portionDescription.isEmpty ? "1 serving" : result.portionDescription,
            servingUnit: result.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "serving" : result.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines),
            confident: result.confident,
            hasExplicitPortion: result.hasExplicitPortion
        )
    }

    func extractMeal(userMessage: String) async throws -> String? {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Identify which meal the user mentioned. If the user didn't say, answer "none".
        Examples:
        - "for breakfast" → breakfast
        - "at dinner" → dinner
        - "as a snack" → snack
        - "I had an apple" → none
        """

        let result = try await respond(
            instructions: instructions,
            userMessage: "User: \(userMessage)",
            generating: MealPick.self
        )

        let m = result.meal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch m {
        case "breakfast", "lunch", "dinner", "snack": return m
        default: return nil
        }
    }

    func extractWaterMutation(userMessage: String) async throws -> WaterMutation {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Parse a water-log request for a nutrition app.
        action add means add the amount to today's water log.
        action delete_all means clear today's water log.
        action update_total means replace today's water total with the specified amount.
        Convert cups or glasses to 8 oz, bottles to 16.9 oz, liters to 33.814 oz, milliliters to oz.
        """
        let result = try await respond(
            instructions: instructions,
            userMessage: "User: \(userMessage)",
            generating: WaterMutationPick.self
        )
        let amount = result.amountOz > 0 ? result.amountOz : nil
        return WaterMutation(action: result.action, amountOz: amount)
    }

    func extractWeightMutation(userMessage: String) async throws -> WeightMutation {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Parse a body-weight log request for a nutrition app.
        action add records a new weight. action update changes an existing weight. action delete removes one existing weight. action delete_all clears all weight entries.
        Convert kg to pounds. dateHint should be today, yesterday, latest, or empty.
        """
        let result = try await respond(
            instructions: instructions,
            userMessage: "User: \(userMessage)",
            generating: WeightMutationPick.self
        )
        let amount = result.weightLbs > 0 ? result.weightLbs : nil
        let hint = result.dateHint.trimmingCharacters(in: .whitespacesAndNewlines)
        return WeightMutation(action: result.action, weightLbs: amount, dateHint: hint.isEmpty ? nil : hint)
    }

    func pickDeleteTargets(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> [String] {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        The user wants to delete entries from their food log. Return the EXACT food names from the log
        that should be deleted. If the user says "delete breakfast", return every breakfast entry's name.
        If the user says "remove the bacon", return only the bacon entry (or all bacon entries).
        For "remove that", "delete that", "remove it", or "delete it", resolve the reference to the most recent logging action in the conversation.
        If the latest assistant confirmation contains multiple food lines created from one request, delete every still-present food from that grouped action. If the latest context singles out one food, delete only that food.
        Short follow-ups such as "both", "all of them", "the other one", "those too", or "them too" continue the immediately preceding delete request or grouped logging action. Return matching names that are still in the log.
        If some members of that referenced group were already deleted, return every referenced member that is still present rather than returning an empty list.
        Example: a grouped action logged A and B, a later delete removed B, and the user follows with "both"; if the current log still contains A, return A.
        If the user says "keep X", do not delete X.
        If the user asks to remove a modifier, topping, add-on, or included component while keeping the main item, delete only that component and not unrelated sides.
        If the user uses relative position language such as "before the last", "previous", "middle", or "between X and Y", use the order in the current food log and recent conversation.
        Never invent names that aren't in the log.
        """

        let history = buildContext(recentMessages: recentMessages)
        let userPrompt = """
        Recent conversation:
        \(history)

        Food log:
        \(logSummary)

        User said: \(userMessage)
        """

        let result = try await respond(
            instructions: instructions,
            userMessage: userPrompt,
            generating: DeletePick.self
        )

        return result.foodNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func pickEditTarget(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> EditTargetSelection {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Pick the exact food name from the log that the user wants to edit.
        Use recent conversation context when the user says things like "that's not right" or "actually".
        If the user only says a vague command like "fix it" without a food, amount, size, or other correction, ask what they want changed instead of choosing the most recent item.
        If multiple separate assistant food lists are in recent context and the user says only "first one" or "second one", ask a clarification question unless the current message also names the meal or food.
        If multiple log entries share the same broad word, ask a clarification question when the user uses only that broad word.
        If you ask a clarification question, leave foodName empty.
        If the user identifies an item by an attribute it lacks, such as "without X", choose the entry whose name/description lacks that attribute.
        If the user says "not X, it was Y", choose the logged entry matching X as the edit target.
        If the user corrects "not the second, the first" or similar, choose the explicitly corrected ordinal item.
        If the user uses temporal/relative wording such as "former", "previous", "before that", or "the one before it", resolve it from recent conversation order. "Former last" means the item that used to be last before a newer item was added, not the current last item.
        If the user says "it" should match "the one before it", choose the current/recent item after that previous entry.
        If you cannot identify one entry confidently, ask a short clarification question.
        """

        let history = buildContext(recentMessages: recentMessages)
        let result = try await respond(
            instructions: instructions,
            userMessage: "\(history)\nFood log:\n\(logSummary)\n\nUser said: \(userMessage)",
            generating: EditTargetPick.self
        )

        let foodName = result.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = result.clarificationQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return EditTargetSelection(
            foodName: foodName.isEmpty ? nil : foodName,
            clarificationQuestion: question.isEmpty ? nil : question
        )
    }

    func resolveEditRequest(
        userMessage: String,
        currentEntryName: String,
        currentEntryBrand: String?,
        currentPortionDescription: String
    ) async throws -> EditResolution {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Interpret the user's correction for the currently logged food.
        If the user did not provide a concrete replacement amount, set hasExplicitPortion to false and ask a short follow-up question.
        Sizes such as "small", "medium", "large", "regular", "kids", "half", or "double" are concrete replacement portions; set hasExplicitPortion to true when the user says one of them.
        Count, weight, and volume units are concrete replacement portions; set hasExplicitPortion to true.
        Fractions of the current item, such as half, quarter, three quarters, or half a sandwich/banana/bowl, are explicit portions; set hasExplicitPortion to true.
        Natural portion phrases such as small handful, bite, sip, scoop, bowl, plate, glass, can, bottle, or packet are explicit enough to edit; set hasExplicitPortion to true.
        If the user says the current item should have the same amount as the entry before it, use the previous entry's portion from conversation context.
        If the current item is too specific to resize directly, provide a neutral replacement search query for the underlying scalable food.
        Leave replacementSearchQuery empty when direct resizing of the current item is appropriate.
        Return a reusable servingUnit in singular form when natural, such as "piece", "slice", "cup", or "serving".
        The servings number must match the corrected count in portionDescription when the unit is countable or fractional.
        """

        let brandLine = currentEntryBrand?.isEmpty == false ? "\nCurrent brand: \(currentEntryBrand!)" : ""
        let result = try await respond(
            instructions: instructions,
            userMessage: "Current entry: \(currentEntryName)\(brandLine)\nCurrent portion: \(currentPortionDescription)\nUser said: \(userMessage)",
            generating: EditResolutionPick.self
        )

        let question = result.clarificationQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementQuery = result.replacementSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return EditResolution(
            servings: max(0.1, result.servings),
            portionDescription: result.portionDescription.isEmpty ? "1 serving" : result.portionDescription,
            servingUnit: result.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "serving" : result.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines),
            confident: result.confident,
            hasExplicitPortion: result.hasExplicitPortion,
            clarificationQuestion: question.isEmpty ? nil : question,
            replacementSearchQuery: replacementQuery.isEmpty ? nil : replacementQuery
        )
    }

    func estimateGrams(
        foodName: String,
        portionDescription: String,
        referenceServingDescription: String?,
        referenceServingGrams: Double?
    ) async throws -> Double {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Given a food and a portion description, estimate the TOTAL weight in grams.
        Use real-world knowledge of typical food weights.
        If a reference serving is provided, scale from it when the requested portion is a subset.

        Examples:
        - "bacon", "2 slices" → 24   (one raw strip ≈ 12 g)
        - "bread", "1 slice"  → 28
        - "milk", "1 cup"     → 244
        - "egg", "1 large"    → 50
        - "rice", "1 cup cooked" → 158
        - "rice", "1/2 cup cooked" → 79
        - "rice", "0.5 cup cooked" → 79
        - "cheddar cheese", "2 slices" → 42
        - "peanut butter", "1 tbsp" → 16
        - when a reference says a serving contains multiple pieces, scale a partial piece count proportionally
        """

        var promptLines = [
            "Food: \(foodName)",
            "Portion: \(portionDescription)"
        ]
        if let referenceServingDescription, let referenceServingGrams {
            promptLines.append("Reference serving: \(referenceServingDescription) ≈ \(Int(referenceServingGrams.rounded())) g")
        }
        let userPrompt = promptLines.joined(separator: "\n")
        let result = try await respond(
            instructions: instructions,
            userMessage: userPrompt,
            generating: GramsEstimate.self
        )

        // Sanity: the model might hallucinate 0 or negatives.
        guard result.grams > 0 else { throw ProviderError.badModelOutput }
        return result.grams
    }

    func generalReply(
        userMessage: String,
        context: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> String {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        You are Nomva, a friendly and knowledgeable nutrition coach. You have full access to the user's food log, weight history, and goals — all provided in the context below.
        When the user asks about their data, DO the math: compute averages, totals, trends, differences, or comparisons across any date range they ask about.
        Show your numbers. Keep answers concise but complete. Use only the data provided.
        If the requested data isn't in the context, say what you do have and suggest logging more.
        """

        var parts: [String] = []
        if !context.isEmpty { parts.append(context) }
        let history = buildContext(recentMessages: recentMessages)
        if !history.isEmpty { parts.append(history) }
        parts.append("User: \(userMessage)")
        let userPrompt = parts.joined(separator: "\n\n")

        let result = try await respond(
            instructions: instructions,
            userMessage: userPrompt,
            generating: ReplyText.self
        )

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    @available(iOS 26.0, *)
    private func respond<T: Generable>(
        instructions: String,
        userMessage: String,
        generating: T.Type
    ) async throws -> T {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )
        let response = try await session.respond(to: userMessage, generating: T.self)
        return response.content
    }

    private func assertAvailable() throws {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:           throw ProviderError.deviceNotEligible
            case .appleIntelligenceNotEnabled: throw ProviderError.intelligenceDisabled
            case .modelNotReady:               throw ProviderError.modelNotReady
            @unknown default:                  throw ProviderError.modelNotReady
            }
        }
    }

    private func buildContext(recentMessages: [(role: String, content: String)]) -> String {
        guard !recentMessages.isEmpty else { return "" }
        return recentMessages.suffix(4).map { msg in
            let role = msg.role == "user" ? "User" : "Assistant"
            return "\(role): \(msg.content)"
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - Split static vs dynamic (legacy)

    private func split(
        systemPrompt: String,
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) -> (instructions: String, userMessage: String) {
        let lines = systemPrompt.components(separatedBy: "\n")

        let dynamicMarkers = ["Goals:", "Date:", "Today's log:", "Nothing logged", "Last "]
        var splitIndex = lines.endIndex
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if dynamicMarkers.contains(where: { trimmed.hasPrefix($0) }) {
                splitIndex = i
                break
            }
        }

        let staticPart  = lines[..<splitIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let dynamicPart = lines[splitIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var contextLines: [String] = []
        for msg in recentMessages.suffix(4) {
            let role = msg.role == "user" ? "User" : "Assistant"
            contextLines.append("\(role): \(msg.content)")
        }

        var enriched = ""
        if !dynamicPart.isEmpty  { enriched += dynamicPart + "\n\n" }
        if !contextLines.isEmpty { enriched += contextLines.joined(separator: "\n") + "\n\n" }
        enriched += "User: \(userMessage)"

        return (staticPart, enriched)
    }

    // MARK: - Legacy structured generation

    @available(iOS 26.0, *)
    private func generateGeneric(
        instructions: String,
        userMessage: String
    ) async throws -> LLMCompletion {
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: instructions
            )
            let response = try await session.respond(
                to: userMessage,
                generating: GeneratedResponse.self
            )
            let json = serializeToJSON(response.content)
            return LLMCompletion(
                text: json,
                providerType: "foundation_models",
                usedFallback: false
            )
        } catch {
            let desc = "\(error)"
            print("⚠️ Foundation Models structured error: \(desc)")

            if desc.contains("UnifiedAssetFramework") || desc.contains("modelcatalog")
                || desc.contains("ModelManagerError") || desc.contains("Code=5000") {
                throw ProviderError.modelNotReady
            }

            // Plain-text fallback
            print("⚠️ Falling back to plain text generation")
            do {
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    instructions: instructions + "\n\nReturn exactly one JSON object and no markdown."
                )
                let textResponse = try await session.respond(to: userMessage)
                let trimmed = textResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)

                let fallbackJSON: String
                if trimmed.contains("{") && trimmed.contains("}") {
                    fallbackJSON = trimmed
                } else {
                    let escaped = trimmed
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    fallbackJSON = "{\"action\":\"reply\",\"text\":\"\(escaped)\"}"
                }

                return LLMCompletion(
                    text: fallbackJSON,
                    providerType: "foundation_models",
                    usedFallback: true
                )
            } catch {
                throw error
            }
        }
    }

    @available(iOS 26.0, *)
    private func serializeToJSON(_ r: GeneratedResponse) -> String {
        var dict: [String: Any] = ["action": r.action]

        if let text = r.text                      { dict["text"] = text }
        if let q    = r.question                  { dict["question"] = q }
        if let meal = r.meal                      { dict["meal"] = meal }
        if let fn   = r.foodName                  { dict["food_name"] = fn }
        if let fns  = r.foodNames, !fns.isEmpty   { dict["food_names"] = fns }
        if let w    = r.weightLbs                 { dict["weight_lbs"] = w }
        if let npg  = r.newPortionGrams           { dict["new_portion_grams"] = npg }
        if let npd  = r.newPortionDescription     { dict["new_portion_description"] = npd }
        if let d    = r.dates, !d.isEmpty         { dict["dates"] = d }
        if let gc   = r.goalCalories              { dict["goal_calories"] = gc }
        if let gp   = r.goalProtein               { dict["goal_protein"] = gp }
        if let gca  = r.goalCarbs                 { dict["goal_carbs"] = gca }
        if let gf   = r.goalFat                   { dict["goal_fat"] = gf }
        if let gfi  = r.goalFiber                 { dict["goal_fiber"] = gfi }

        if let queries = r.queries, !queries.isEmpty {
            dict["queries"] = queries.map { q in
                ["q": q.q, "description": q.description, "meal": q.meal] as [String: Any]
            }
        }

        if let items = r.items, !items.isEmpty {
            dict["items"] = items.map { item in
                var d: [String: Any] = [
                    "portion_description": item.portionDescription,
                    "servings": item.servings,
                    "meal": item.meal
                ]
                if let foodName = item.foodName   { d["food_name"] = foodName }
                if let search = item.searchQuery  { d["search_query"] = search }
                if let cid = item.candidateId     { d["candidate_id"] = cid }
                if let fid = item.fdcId           { d["fdc_id"] = fid }
                return d
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else {
            return "{\"action\":\"reply\",\"text\":\"Something went wrong.\"}"
        }
        return str
    }

    // MARK: - Errors

    enum ProviderError: LocalizedError {
        case unsupportedOS, deviceNotEligible, intelligenceDisabled, modelNotReady, badModelOutput

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:        return "On-device logging requires iOS 26 or newer."
            case .deviceNotEligible:    return "Apple Intelligence isn't available on this device."
            case .intelligenceDisabled: return "Enable Apple Intelligence in Settings → Apple Intelligence & Siri."
            case .modelNotReady:        return "The on-device model is still downloading. Try again in a minute."
            case .badModelOutput:       return "The model produced an invalid value."
            }
        }
    }
}
