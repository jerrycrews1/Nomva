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
    case queryData    = "query_data"
    case logWeight    = "log_weight"
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
    @Guide(description: "True if the user clearly stated an amount, false if you had to guess.")
    var confident: Bool
}

@available(iOS 26, *)
@Generable
struct MealPick {
    @Guide(description: "Exactly one of: breakfast, lunch, dinner, snack, or none if the user gave no hint.")
    var meal: String
}

@available(iOS 26, *)
@Generable
struct DeletePick {
    @Guide(description: "Exact food names from the log the user wants to delete. Use the names exactly as they appear in the provided log.")
    var foodNames: [String]
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

        edit_food — user wants to change a portion they already logged.
          "make the bacon 3 slices" → edit_food
          "that was 1 cup not 2"    → edit_food

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

        log_weight — user is recording a body-weight measurement.
          "I weigh 180 lbs" → log_weight

        set_goal — user wants to change their calorie or macro target.
          "set my calorie goal to 2000" → set_goal

        reply — ONLY for greetings, small talk, or questions about the app itself.
          "hi"           → reply
          "thanks"       → reply
          "how do I use this app?" → reply

        If the message mentions food the user ate, drank, or had, the answer is
        log_food — never reply.
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
        case .queryData:  return .queryData
        case .logWeight:  return .logWeight
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
        Return just the food phrases — no quantities, no meal names.
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
        Examples:
        - "2 slices of bacon" → servings: 2, portionDescription: "2 slices", confident: true
        - "a cup of rice" → servings: 1, portionDescription: "1 cup", confident: true
        - "some chicken" → servings: 1, portionDescription: "1 serving", confident: false
        - "half an avocado" → servings: 0.5, portionDescription: "1/2 avocado", confident: true
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
            confident: result.confident
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

    func pickDeleteTargets(
        userMessage: String,
        logSummary: String
    ) async throws -> [String] {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        The user wants to delete entries from their food log. Return the EXACT food names from the log
        that should be deleted. If the user says "delete breakfast", return every breakfast entry's name.
        If the user says "remove the bacon", return only the bacon entry (or all bacon entries).
        Never invent names that aren't in the log.
        """

        let userPrompt = """
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

    func estimateGrams(
        foodName: String,
        portionDescription: String
    ) async throws -> Double {
        guard #available(iOS 26.0, *) else { throw ProviderError.unsupportedOS }
        try assertAvailable()

        let instructions = """
        Given a food and a portion description, estimate the TOTAL weight in grams.
        Use real-world knowledge of typical food weights.

        Examples:
        - "bacon", "2 slices" → 24   (one raw strip ≈ 12 g)
        - "bread", "1 slice"  → 28
        - "milk", "1 cup"     → 244
        - "egg", "1 large"    → 50
        - "chicken breast", "6 oz" → 170
        - "rice", "1 cup cooked" → 158
        - "cheddar cheese", "2 slices" → 42
        - "peanut butter", "1 tbsp" → 16
        """

        let userPrompt = "Food: \(foodName)\nPortion: \(portionDescription)"
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
            print("🤖 Structured response: \(json)")
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
