import Foundation

private enum CandidateSource: String {
    case database, custom, recent
}

private struct SearchCandidate {
    let candidateId: String
    let source: CandidateSource
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
    let per100gValues: NutritionValues
    var score: Int = 0

    func scaled(to grams: Double) -> NutritionValues {
        let base = (servingGrams ?? 100) > 0 ? (servingGrams ?? 100) : 100
        let factor = grams / base
        return NutritionValues(
            calories: caloriesPerServing * factor, protein: proteinG * factor, carbs: carbsG * factor,
            fat: fatG * factor, fiber: fiberG * factor, sugar: sugarG * factor, sodium: sodiumMg * factor
        )
    }
    var per100g: NutritionValues { per100gValues }
}

@MainActor
final class FoodLoggingService {
    static let shared = FoodLoggingService()
    private let db = DatabaseManager.shared

    enum ChatAction {
        case logFood([FoodEntry])
        case replaceEntry(deleteName: String, newEntries: [FoodEntry])
        case editEntry(foodName: String, newGrams: Double, newDescription: String)
        case deleteEntry(foodNames: [String])
        case deleteMeal(meal: String)
        case deleteAllWeights
        case log_weight(WeightEntry)
        case updateWeight(id: String, weightLbs: Double)
        case deleteWeight(date: String)
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

        // Step 1: Classify intent
        let intent: UserIntentKind
        do {
            intent = try await provider.classifyIntent(
                userMessage: userMessage,
                recentMessages: recentMessages
            )
            print("🎯 Intent: \(intent.rawValue)")
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
                dayLabel: dayLabel
            )

        case .editFood:
            return await handleEditFood(
                userMessage: userMessage,
                provider: provider,
                dayEntries: dayEntries,
                dayLabel: dayLabel,
                recentEntries: recentEntries,
                customFoods: customFoods,
                recentMessages: recentMessages
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
                recentMessages: recentMessages
            )

        case .logWeight:
            return await handleLogWeight(userMessage: userMessage, provider: provider, recentMessages: recentMessages)

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
            print("🍽 Split foods: \(foodMentions)")
        } catch {
            return handleProviderError(error)
        }

        // Step 3: Extract meal
        let meal: String
        do {
            meal = try await provider.extractMeal(userMessage: userMessage) ?? "snack"
            print("🕐 Meal: \(meal)")
        } catch {
            meal = "snack"
        }

        var entries: [FoodEntry] = []
        var confirmLines: [String] = []

        for mention in foodMentions {
            // Step 4: Search the database
            let candidates = await searchCandidates(query: mention, recentEntries: recentEntries, customFoods: customFoods)
            guard let bestCandidate = candidates.first else {
                confirmLines.append("Couldn't find \"\(mention)\" in the database")
                continue
            }

            // Step 5: Confirm match
            let isMatch: Bool
            do {
                isMatch = try await provider.confirmFoodMatch(
                    userMessage: userMessage,
                    foodMention: mention,
                    candidateName: bestCandidate.name,
                    candidateBrand: bestCandidate.brand
                )
                print("✅ Match \"\(mention)\" → \"\(bestCandidate.name)\": \(isMatch)")
            } catch {
                print("⚠️ confirmMatch failed, using best candidate anyway")
                isMatch = true
            }

            let candidate = isMatch ? bestCandidate : (candidates.dropFirst().first ?? bestCandidate)

            // Step 6: Extract servings
            let servingsInfo: ServingsInfo
            do {
                servingsInfo = try await provider.extractServings(
                    userMessage: userMessage,
                    foodMention: mention,
                    candidateName: candidate.name,
                    candidateServingDescription: candidate.servingDesc
                )
                print("📏 Servings: \(servingsInfo.servings) (\(servingsInfo.portionDescription))")
            } catch {
                print("⚠️ extractServings failed, using 1 serving")
                servingsInfo = ServingsInfo(servings: 1, portionDescription: "1 serving", confident: false)
            }

            // Step 7: Estimate grams
            let grams: Double
            if servingsInfo.portionDescription.lowercased() != "1 serving" {
                do {
                    grams = try await provider.estimateGrams(
                        foodName: candidate.name,
                        portionDescription: servingsInfo.portionDescription
                    )
                    print("⚖️ Estimated grams: \(grams)")
                } catch {
                    // Fallback: servings × serving size
                    grams = servingsInfo.servings * (candidate.servingGrams ?? 100)
                    print("⚠️ estimateGrams failed, fallback: \(grams)g")
                }
            } else {
                grams = servingsInfo.servings * (candidate.servingGrams ?? 100)
            }

            // Deduplication: only skip if we already added this food in THIS message
            if entries.contains(where: { $0.name == candidate.name && $0.meal == meal }) {
                continue
            }

            // Build the entry
            let nut = candidate.scaled(to: grams)
            let per100 = candidate.per100g

            entries.append(FoodEntry(
                name: candidate.name, brand: candidate.brand, meal: meal,
                portionGrams: grams, portionDescription: servingsInfo.portionDescription,
                calories: nut.calories, proteinG: nut.protein, carbsG: nut.carbs, fatG: nut.fat, fiberG: nut.fiber, sugarG: nut.sugar, sodiumMg: nut.sodium,
                caloriesPer100g: per100.calories, proteinPer100g: per100.protein, carbsPer100g: per100.carbs, fatPer100g: per100.fat, fiberPer100g: per100.fiber,
                rawUserInput: userMessage, fdcId: candidate.fdcId
            ))
            confirmLines.append("\(candidate.name) (\(servingsInfo.portionDescription)) — \(Int(nut.calories)) cal")
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
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        guard !dayEntries.isEmpty else {
            return .reply("Your log for \(dayLabel) is empty — nothing to edit.")
        }

        // Figure out which food to edit from the selected day
        let logSummary = dayEntries.map { "\($0.name) (\($0.meal))" }.joined(separator: "\n")
        let targets: [String]
        do {
            targets = try await provider.pickDeleteTargets(
                userMessage: userMessage,
                logSummary: logSummary
            )
        } catch {
            // Fallback: assume it's the most recently logged item
            if let last = dayEntries.last {
                return await applyEdit(userMessage: userMessage, provider: provider, entry: last)
            }
            return .reply("I couldn't figure out which item to edit.")
        }

        // Find the matching entry
        guard let targetName = targets.first,
              let entry = dayEntries.first(where: { $0.name.lowercased() == targetName.lowercased() })
                ?? dayEntries.last else {
            // If GPT couldn't match, edit the most recent entry
            if let last = dayEntries.last {
                return await applyEdit(userMessage: userMessage, provider: provider, entry: last)
            }
            return .reply("I couldn't figure out which item to edit.")
        }

        return await applyEdit(userMessage: userMessage, provider: provider, entry: entry)
    }

    private func applyEdit(
        userMessage: String,
        provider: any LLMProvider,
        entry: FoodEntry
    ) async -> LoggingResult {
        // Extract the new servings info from the user message
        let servingsInfo: ServingsInfo
        do {
            servingsInfo = try await provider.extractServings(
                userMessage: userMessage,
                foodMention: entry.name,
                candidateName: entry.name,
                candidateServingDescription: entry.portionDescription
            )
        } catch {
            return .reply("I couldn't understand the new portion. Try \"make it 2 servings\" or \"change to 3 slices\".")
        }

        // Estimate grams for the new portion
        let newGrams: Double
        if servingsInfo.portionDescription.lowercased() != "1 serving" {
            newGrams = (try? await provider.estimateGrams(
                foodName: entry.name,
                portionDescription: servingsInfo.portionDescription
            )) ?? servingsInfo.servings * entry.portionGrams
        } else {
            newGrams = servingsInfo.servings * entry.portionGrams
        }

        return .init(
            action: .editEntry(
                foodName: entry.name,
                newGrams: newGrams,
                newDescription: servingsInfo.portionDescription
            ),
            reply: "✓ Updated \(entry.name) to \(servingsInfo.portionDescription)"
        )
    }

    // MARK: - Delete Food

    private func handleDeleteFood(
        userMessage: String,
        provider: any LLMProvider,
        dayEntries: [FoodEntry],
        dayLabel: String
    ) async -> LoggingResult {
        let logSummary = dayEntries.map { "\($0.name) (\($0.meal))" }.joined(separator: "\n")
        guard !logSummary.isEmpty else {
            return .reply("Your log for \(dayLabel) is empty — nothing to delete.")
        }

        do {
            let targets = try await provider.pickDeleteTargets(
                userMessage: userMessage,
                logSummary: logSummary
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
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        let context = buildDataContext(
            goals: goals,
            dayEntries: dayEntries,
            dayLabel: dayLabel,
            recentEntries: recentEntries,
            weightEntries: weightEntries
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
        weightEntries: [WeightEntry]
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

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Log Weight

    private func handleLogWeight(
        userMessage: String,
        provider: any LLMProvider,
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        // Try to find a decimal number pattern
        let pattern = #"(\d+\.?\d*)\s*(lbs?|pounds?|kg|kilos?)?"#
        if let match = userMessage.range(of: pattern, options: .regularExpression) {
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
        recentMessages: [(role: String, content: String)]
    ) async -> LoggingResult {
        let context = buildDataContext(
            goals: goals,
            dayEntries: dayEntries,
            dayLabel: dayLabel,
            recentEntries: recentEntries,
            weightEntries: weightEntries
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

    private func searchCandidates(query: String, recentEntries: [FoodEntry], customFoods: [CustomFood]) async -> [SearchCandidate] {
        let foods = await db.search(query: query, limit: 15)
        var all = buildDatabaseCandidates(from: foods)
        all.append(contentsOf: buildCustomCandidates(from: customFoods))
        all.append(contentsOf: buildRecentCandidates(from: recentEntries))
        return all.map { var c = $0; c.score = calculateScore(c, query: query); return c }
                  .sorted { $0.score > $1.score }.prefix(10).map { $0 }
    }

    private func calculateScore(_ candidate: SearchCandidate, query: String) -> Int {
        let q = query.lowercased()
        let name = candidate.name.lowercased()
        var score = 0
        for token in q.components(separatedBy: .whitespaces) where !token.isEmpty {
            if name.contains(token) { score += 10 }
        }
        return score
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

    private func buildDatabaseCandidates(from foods: [FoodItem]) -> [SearchCandidate] {
        foods.map {
            SearchCandidate(
                candidateId: "db_\($0.id)",
                source: CandidateSource.database,
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
                per100gValues: $0.per100g
            )
        }
    }

    private func buildCustomCandidates(from foods: [CustomFood]) -> [SearchCandidate] {
        foods.map { SearchCandidate(candidateId: "custom_\(String($0.id.uuidString.prefix(10)))", source: CandidateSource.custom, fdcId: nil, customFoodId: $0.id, recentEntryId: nil, name: $0.name, brand: $0.brand, servingGrams: $0.servingGrams, servingDesc: $0.servingDesc, caloriesPerServing: $0.calories, proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG, fiberG: $0.fiberG, sugarG: 0, sodiumMg: 0, per100gValues: NutritionValues(calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0, sodium: 0)) }
    }

    private func buildRecentCandidates(from entries: [FoodEntry]) -> [SearchCandidate] {
        entries.prefix(10).map { SearchCandidate(candidateId: "recent_\(String($0.id.uuidString.prefix(10)))", source: CandidateSource.recent, fdcId: $0.fdcId, customFoodId: nil, recentEntryId: $0.id, name: $0.name, brand: $0.brand, servingGrams: $0.portionGrams, servingDesc: $0.portionDescription, caloriesPerServing: $0.calories, proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG, fiberG: $0.fiberG, sugarG: $0.sugarG, sodiumMg: $0.sodiumMg, per100gValues: NutritionValues(calories: $0.caloriesPer100g, protein: $0.proteinPer100g, carbs: $0.carbsPer100g, fat: $0.fatPer100g, fiber: $0.fiberPer100g, sugar: 0, sodium: 0)) }
    }

    private func shortID(_ uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}

private extension FoodLoggingService.LoggingResult {
    static func reply(_ text: String) -> FoodLoggingService.LoggingResult {
        .init(action: .reply(text), reply: text)
    }
}
