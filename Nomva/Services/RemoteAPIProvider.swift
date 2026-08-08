import Foundation
import CoreFoundation
import AuthenticationServices
import Combine
import CryptoKit
import DeviceCheck
import Security
import StoreKit
import UIKit

/// Calls the Nomva API server (Node.js on Lightsail) which proxies to the configured OpenAI model.
/// Each method mirrors the focused LLMProvider protocol — one tiny call per step.
/// Used as a fallback when Apple Foundation Models aren't available or misbehave.
struct RemoteAPIProvider: LLMProvider {

    /// Clamp a model-provided servings value to a sane, finite range. Calories
    /// are computed by multiplying this number, and `Int(Double)` traps on
    /// non-finite results, so no unbounded value may leave this file.
    private func clampedServings(_ value: Double?, fallback: Double = 1) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(0.1, value), 100)
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            // JSONSerialization represents both booleans and numbers as
            // NSNumber. Swift also reports numeric 0 and 1 as `is Bool`, so
            // that check incorrectly discarded legitimate zero-valued
            // nutrients such as fiber. CFBoolean has a distinct runtime type.
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            number = value.doubleValue
        } else if let value = value as? Double {
            number = value
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private func nonemptyString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedFoodCandidate(from json: [String: Any]) -> ResolvedFoodCandidate? {
        guard let candidateId = nonemptyString(json["candidateId"]),
              let name = nonemptyString(json["name"]) else {
            return nil
        }

        let servings = clampedServings(finiteNumber(json["servings"]))
        return ResolvedFoodCandidate(
            candidateId: candidateId,
            name: name,
            brand: nonemptyString(json["brand"]),
            source: nonemptyString(json["source"]),
            servings: servings,
            portionDescription: nonemptyString(json["portionDescription"]) ?? "1 serving",
            servingUnit: nonemptyString(json["servingUnit"]) ?? "serving",
            confident: json["confident"] as? Bool ?? false,
            hasExplicitPortion: json["hasExplicitPortion"] as? Bool ?? false,
            servingGrams: finiteNumber(json["servingGrams"]),
            servingDescription: nonemptyString(json["servingDescription"]),
            caloriesPerServing: finiteNumber(json["caloriesPerServing"]),
            proteinG: finiteNumber(json["proteinG"]),
            carbsG: finiteNumber(json["carbsG"]),
            fatG: finiteNumber(json["fatG"]),
            fiberG: finiteNumber(json["fiberG"]),
            sugarG: finiteNumber(json["sugarG"]),
            sodiumMg: finiteNumber(json["sodiumMg"]),
            portionBasis: nonemptyString(json["portionBasis"]),
            quality: nonemptyString(json["quality"]),
            confidence: finiteNumber(json["confidence"]),
            sourceURL: nonemptyString(json["sourceUrl"]),
            sourceTitle: nonemptyString(json["sourceTitle"]),
            evidence: nonemptyString(json["evidence"])
        )
    }

    // MARK: - Configuration

    /// Base URL of the Nomva API server (no trailing slash).
    /// In production: "https://nomva.nerdquad.com"
    private let baseURL: String

    init(baseURL: String = "https://nomva.nerdquad.com") {
        self.baseURL = baseURL
    }

    // MARK: - LLMProvider Conformance

    func complete(
        systemPrompt: String,
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> LLMCompletion {
        // The remote server doesn't have a legacy complete() — use general-reply instead.
        let text = try await generalReply(
            userMessage: userMessage,
            context: systemPrompt,
            recentMessages: recentMessages
        )
        return LLMCompletion(
            text: "{\"action\":\"reply\",\"text\":\"\(text.escapedForJSON())\"}",
            providerType: "remote_api",
            usedFallback: false
        )
    }

    func classifyIntent(
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> UserIntentKind {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "recentMessages": recentMessages.map { ["role": $0.role, "content": $0.content] }
        ]
        let result: [String: String] = try await post("/v1/classify-intent", body: body)
        guard let raw = result["intent"],
              let kind = UserIntentKind(rawValue: raw) else {
            return .reply
        }
        return kind
    }

    func splitFoods(userMessage: String) async throws -> [String] {
        let body: [String: Any] = ["userMessage": userMessage]
        let result: [String: [String]] = try await post("/v1/split-foods", body: body)
        return result["foods"] ?? [userMessage]
    }

    func planFoodLog(userMessage: String) async throws -> FoodLogPlan {
        let data = try await postRaw(
            "/v1/plan-food-log",
            body: ["userMessage": userMessage],
            timeout: 25
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rawItems = json["items"] as? [[String: Any]] ?? []
        let foods = rawItems.prefix(12).compactMap { item -> PlannedFoodMention? in
            guard let mention = nonemptyString(item["mention"]) else { return nil }
            let servings = clampedServings(finiteNumber(item["servings"]))
            return PlannedFoodMention(
                text: mention,
                searchQuery: nonemptyString(item["searchQuery"]) ?? mention,
                kind: nonemptyString(item["kind"]) ?? "single",
                servingsInfo: ServingsInfo(
                    servings: servings,
                    portionDescription: nonemptyString(item["portionDescription"]) ?? "1 serving",
                    servingUnit: nonemptyString(item["servingUnit"]) ?? "serving",
                    confident: item["confident"] as? Bool ?? false,
                    hasExplicitPortion: item["hasExplicitPortion"] as? Bool ?? false
                )
            )
        }
        guard !foods.isEmpty else { throw RemoteError.invalidResponse }

        let rawMeal = nonemptyString(json["meal"])
        let meal = ["breakfast", "lunch", "dinner", "snack"].contains(rawMeal ?? "")
            ? rawMeal
            : nil
        return FoodLogPlan(
            meal: meal,
            quantityScope: nonemptyString(json["quantityScope"]) ?? "none",
            globalServings: finiteNumber(json["globalServings"]),
            foods: foods
        )
    }

    func buildFoodSearchQuery(
        userMessage: String,
        foodMention: String
    ) async throws -> String {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention
        ]
        let result: [String: String] = try await post("/v1/build-food-search-query", body: body)
        let query = result["query"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (query?.isEmpty == false) ? query! : foodMention
    }

    func resolveFoodCandidate(
        userMessage: String,
        foodMention: String
    ) async throws -> ResolvedFoodCandidate {
        try await resolveFoodCandidate(
            userMessage: userMessage,
            foodMention: foodMention,
            searchQuery: nil,
            resolutionHint: nil
        )
    }

    private func resolveFoodCandidate(
        userMessage: String,
        foodMention: String,
        searchQuery: String?,
        resolutionHint: String?
    ) async throws -> ResolvedFoodCandidate {
        var body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention,
        ]
        if let searchQuery, !searchQuery.isEmpty {
            body["searchQuery"] = searchQuery
        }
        if let resolutionHint, !resolutionHint.isEmpty {
            body["resolutionHint"] = resolutionHint
        }
        let data: Data
        do {
            // Local catalog selection is bounded server-side; the longer client
            // budget is reserved for a genuinely missing menu item that needs
            // a current web lookup.
            data = try await postRaw("/v1/resolve-food-candidate", body: body, timeout: 30)
        } catch RemoteError.serverError(422) {
            throw ResolveFoodCandidateError.noMatch
        } catch RemoteError.serverError(501) {
            throw ResolveFoodCandidateError.unsupported
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let candidate = resolvedFoodCandidate(from: json) else {
            throw ResolveFoodCandidateError.invalidResponse
        }
        return candidate
    }

    func searchFoodCatalog(query: String) async throws -> [ResolvedFoodCandidate] {
        let data = try await postRaw(
            "/v1/search-food-catalog",
            body: ["query": query],
            timeout: 30
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let foods = json["foods"] as? [[String: Any]] ?? []
        return foods.compactMap(resolvedFoodCandidate(from:))
    }

    func resolveFoodCandidates(
        userMessage: String,
        foodMentions: [String],
        searchQueries: [String] = [],
        resolutionHints: [String?] = []
    ) async -> [ResolvedFoodCandidate?] {
        await withTaskGroup(of: (Int, ResolvedFoodCandidate?).self) { group in
            for (index, mention) in foodMentions.enumerated() {
                group.addTask {
                    do {
                        return (
                            index,
                            try await self.resolveFoodCandidate(
                                userMessage: userMessage,
                                foodMention: mention,
                                searchQuery: searchQueries.indices.contains(index)
                                    ? searchQueries[index]
                                    : nil,
                                resolutionHint: resolutionHints.indices.contains(index)
                                    ? resolutionHints[index]
                                    : nil
                            )
                        )
                    } catch {
                        return (index, nil)
                    }
                }
            }

            var resolved = Array<ResolvedFoodCandidate?>(repeating: nil, count: foodMentions.count)
            for await (index, candidate) in group {
                resolved[index] = candidate
            }
            return resolved
        }
    }

    func extractServingsBatch(
        userMessage: String,
        foodMentions: [String]
    ) async -> [ServingsInfo] {
        await withTaskGroup(of: (Int, ServingsInfo).self) { group in
            for (index, mention) in foodMentions.enumerated() {
                group.addTask {
                    do {
                        return (
                            index,
                            try await self.extractServings(
                                userMessage: userMessage,
                                foodMention: mention,
                                candidateName: mention,
                                candidateServingDescription: nil
                            )
                        )
                    } catch {
                        return (
                            index,
                            ServingsInfo(
                                servings: 1,
                                portionDescription: "1 serving",
                                servingUnit: "serving",
                                confident: false,
                                hasExplicitPortion: false
                            )
                        )
                    }
                }
            }

            var portions = Array(
                repeating: ServingsInfo(
                    servings: 1,
                    portionDescription: "1 serving",
                    servingUnit: "serving",
                    confident: false,
                    hasExplicitPortion: false
                ),
                count: foodMentions.count
            )
            for await (index, portion) in group {
                portions[index] = portion
            }
            return portions
        }
    }

    func chooseFoodCandidate(
        userMessage: String,
        foodMention: String,
        candidates: [FoodChoiceOption]
    ) async throws -> Int? {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention,
            "candidates": candidates.enumerated().map { index, candidate in
                var json: [String: Any] = [
                    "index": index,
                    "name": candidate.name,
                    "caloriesPerServing": candidate.caloriesPerServing,
                    "portionBasis": candidate.portionBasis
                ]
                if let brand = candidate.brand {
                    json["brand"] = brand
                }
                if let servingDescription = candidate.servingDescription {
                    json["servingDescription"] = servingDescription
                }
                if let source = candidate.source {
                    json["source"] = source
                }
                return json
            }
        ]
        let data = try await postRaw("/v1/choose-food-candidate", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["candidateIndex"] as? Int
    }

    func validateFoodCandidate(
        userMessage: String,
        foodMention: String,
        searchQuery: String,
        candidate: FoodChoiceOption,
        servingsInfo: ServingsInfo
    ) async throws -> FoodCandidateValidation {
        var body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention,
            "searchQuery": searchQuery,
            "candidate": [
                "name": candidate.name,
                "caloriesPerServing": candidate.caloriesPerServing,
                "portionBasis": candidate.portionBasis,
            ],
            "servingsInfo": [
                "servings": servingsInfo.servings,
                "portionDescription": servingsInfo.portionDescription,
                "servingUnit": servingsInfo.servingUnit,
                "confident": servingsInfo.confident,
                "hasExplicitPortion": servingsInfo.hasExplicitPortion,
            ]
        ]
        if let brand = candidate.brand {
            var candidateJSON = body["candidate"] as? [String: Any] ?? [:]
            candidateJSON["brand"] = brand
            body["candidate"] = candidateJSON
        }
        if let servingDescription = candidate.servingDescription {
            var candidateJSON = body["candidate"] as? [String: Any] ?? [:]
            candidateJSON["servingDescription"] = servingDescription
            body["candidate"] = candidateJSON
        }
        if let source = candidate.source {
            var candidateJSON = body["candidate"] as? [String: Any] ?? [:]
            candidateJSON["source"] = source
            body["candidate"] = candidateJSON
        }

        let data = try await postRaw("/v1/validate-food-candidate", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return FoodCandidateValidation(
            keepCurrentCandidate: json["keepCurrentCandidate"] as? Bool ?? true,
            servings: clampedServings(json["servings"] as? Double, fallback: clampedServings(servingsInfo.servings)),
            portionDescription: json["portionDescription"] as? String ?? servingsInfo.portionDescription,
            servingUnit: json["servingUnit"] as? String ?? servingsInfo.servingUnit,
            confident: json["confident"] as? Bool ?? servingsInfo.confident,
            hasExplicitPortion: json["hasExplicitPortion"] as? Bool ?? servingsInfo.hasExplicitPortion,
            replacementSearchQuery: json["replacementSearchQuery"] as? String
        )
    }

    func confirmFoodMatch(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateBrand: String?
    ) async throws -> Bool {
        var body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention,
            "candidateName": candidateName
        ]
        if let brand = candidateBrand { body["candidateBrand"] = brand }
        let result: [String: Bool] = try await post("/v1/confirm-match", body: body)
        return result["isMatch"] ?? false
    }

    func extractServings(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateServingDescription: String?
    ) async throws -> ServingsInfo {
        var body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention,
            "candidateName": candidateName
        ]
        if let desc = candidateServingDescription { body["candidateServingDescription"] = desc }

        let data = try await postRaw("/v1/extract-servings", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return ServingsInfo(
            servings: clampedServings(json["servings"] as? Double),
            portionDescription: json["portionDescription"] as? String ?? "1 serving",
            servingUnit: json["servingUnit"] as? String ?? "serving",
            confident: json["confident"] as? Bool ?? false,
            hasExplicitPortion: json["hasExplicitPortion"] as? Bool ?? false
        )
    }

    func extractMeal(userMessage: String) async throws -> String? {
        let body: [String: Any] = ["userMessage": userMessage]
        let result: [String: String?] = try await post("/v1/extract-meal", body: body)
        return result["meal"] ?? nil
    }

    func extractWaterMutation(userMessage: String) async throws -> WaterMutation {
        let body: [String: Any] = ["userMessage": userMessage]
        let data = try await postRaw("/v1/extract-water-mutation", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return WaterMutation(
            action: (json["action"] as? String) ?? "reply",
            amountOz: json["amountOz"] as? Double
        )
    }

    func extractWeightMutation(userMessage: String) async throws -> WeightMutation {
        let body: [String: Any] = ["userMessage": userMessage]
        let data = try await postRaw("/v1/extract-weight-mutation", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return WeightMutation(
            action: (json["action"] as? String) ?? "reply",
            weightLbs: json["weightLbs"] as? Double,
            dateHint: json["dateHint"] as? String
        )
    }

    func extractFoodMove(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> FoodMoveMutation {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "logSummary": logSummary,
            "recentMessages": recentMessages.map { ["role": $0.role, "content": $0.content] }
        ]
        let data = try await postRaw("/v1/extract-food-move", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return FoodMoveMutation(
            foodName: json["foodName"] as? String,
            destinationMeal: json["destinationMeal"] as? String,
            clarificationQuestion: json["clarificationQuestion"] as? String,
            moveAll: json["moveAll"] as? Bool ?? false,
            sourceMeal: json["sourceMeal"] as? String
        )
    }

    func pickDeleteTargets(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> [String] {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "logSummary": logSummary,
            "recentMessages": recentMessages.map { ["role": $0.role, "content": $0.content] }
        ]
        let result: [String: [String]] = try await post("/v1/pick-delete-targets", body: body)
        return result["foodNames"] ?? []
    }

    func pickEditTarget(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> EditTargetSelection {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "logSummary": logSummary,
            "recentMessages": recentMessages.map { ["role": $0.role, "content": $0.content] }
        ]
        let data = try await postRaw("/v1/pick-edit-target", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return EditTargetSelection(
            foodName: json["foodName"] as? String,
            clarificationQuestion: json["clarificationQuestion"] as? String
        )
    }

    func resolveEditRequest(
        userMessage: String,
        currentEntryName: String,
        currentEntryBrand: String?,
        currentPortionDescription: String
    ) async throws -> EditResolution {
        var body: [String: Any] = [
            "userMessage": userMessage,
            "currentEntryName": currentEntryName,
            "currentPortionDescription": currentPortionDescription
        ]
        if let currentEntryBrand {
            body["currentEntryBrand"] = currentEntryBrand
        }

        let data = try await postRaw("/v1/resolve-edit-request", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return EditResolution(
            servings: clampedServings(json["servings"] as? Double),
            portionDescription: json["portionDescription"] as? String ?? "1 serving",
            servingUnit: json["servingUnit"] as? String ?? "serving",
            confident: json["confident"] as? Bool ?? false,
            hasExplicitPortion: json["hasExplicitPortion"] as? Bool ?? false,
            clarificationQuestion: json["clarificationQuestion"] as? String,
            replacementSearchQuery: json["replacementSearchQuery"] as? String
        )
    }

    func estimateGrams(
        foodName: String,
        portionDescription: String,
        referenceServingDescription: String?,
        referenceServingGrams: Double?
    ) async throws -> Double {
        let body: [String: Any] = [
            "foodName": foodName,
            "portionDescription": portionDescription
        ]
        var mutableBody = body
        if let referenceServingDescription {
            mutableBody["referenceServingDescription"] = referenceServingDescription
        }
        if let referenceServingGrams {
            mutableBody["referenceServingGrams"] = referenceServingGrams
        }
        let data = try await postRaw("/v1/estimate-grams", body: mutableBody)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let grams = json["grams"] as? Double, grams.isFinite, grams > 0, grams <= 5000 else {
            throw RemoteError.invalidResponse
        }
        return grams
    }

    func findFoodStep(
        userMessage: String,
        foodMention: String,
        history: [FindFoodHistoryRound]
    ) async throws -> FindFoodStep {
        let historyJSON: [[String: Any]] = history.map { round in
            let candidates: [[String: Any]] = round.candidates.enumerated().map { index, candidate in
                var json: [String: Any] = [
                    "index": index,
                    "name": candidate.name,
                    "caloriesPerServing": candidate.caloriesPerServing,
                    "portionBasis": candidate.portionBasis,
                ]
                if let brand = candidate.brand { json["brand"] = brand }
                if let servingDescription = candidate.servingDescription { json["servingDescription"] = servingDescription }
                if let source = candidate.source { json["source"] = source }
                return json
            }
            return [
                "query": round.query,
                "candidates": candidates,
            ]
        }
        let body: [String: Any] = [
            "userMessage": userMessage,
            "foodMention": foodMention,
            "history": historyJSON,
        ]
        let data = try await postRaw("/v1/find-food-step", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let action = (json["action"] as? String)?.lowercased() ?? ""
        switch action {
        case "search":
            guard let query = (json["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                throw FindFoodStepError.invalidResponse
            }
            return .search(query: query)
        case "pick":
            guard let round = json["round"] as? Int,
                  let candidateIndex = json["candidateIndex"] as? Int else {
                throw FindFoodStepError.invalidResponse
            }
            let servingsInfo = ServingsInfo(
                servings: clampedServings(json["servings"] as? Double),
                portionDescription: (json["portionDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1 serving",
                servingUnit: (json["servingUnit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "serving",
                confident: json["confident"] as? Bool ?? false,
                hasExplicitPortion: json["hasExplicitPortion"] as? Bool ?? false
            )
            return .pick(round: round, candidateIndex: candidateIndex, servingsInfo: servingsInfo)
        case "give_up":
            return .giveUp
        default:
            throw FindFoodStepError.invalidResponse
        }
    }

    func generalReply(
        userMessage: String,
        context: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> String {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "context": context,
            "recentMessages": recentMessages.map { ["role": $0.role, "content": $0.content] }
        ]
        let result: [String: String] = try await post("/v1/general-reply", body: body)
        return result["text"] ?? "I'm not sure how to answer that."
    }

    func extractGoalChanges(userMessage: String) async throws -> [GoalChange] {
        let body: [String: Any] = ["userMessage": userMessage]
        let data = try await postRaw("/v1/extract-goal", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rawChanges = json["changes"] as? [[String: Any]] ?? []
        return rawChanges.compactMap { change in
            guard let metric = change["metric"] as? String,
                  let operation = change["operation"] as? String,
                  let value = change["value"] as? Double,
                  value > 0 else {
                return nil
            }
            return GoalChange(metric: metric, operation: operation, value: value)
        }
    }

    func parseDataQueries(userMessage: String) async throws -> [DataQuerySpec] {
        let data = try await postRaw("/v1/parse-data-query", body: ["userMessage": userMessage])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let queries = json["queries"] as? [[String: Any]] ?? []
        return queries.compactMap { query in
            guard let metric = query["metric"] as? String,
                  let aggregation = query["aggregation"] as? String,
                  let window = query["window"] as? String else {
                return nil
            }
            return DataQuerySpec(
                metric: metric,
                aggregation: aggregation,
                window: window,
                days: query["days"] as? Int
            )
        }
    }

    // MARK: - Recent Food Suggestions

    struct RecentFoodSuggestionCandidate {
        let id: String
        let name: String
        let brand: String?
        let recentCount: Int
        let sameWeekdayCount: Int
        let isFavorite: Bool
        let lastLoggedAt: Date
        let mealCounts: [String: Int]
    }

    struct RecentFoodSuggestionResult: Codable {
        let candidateIds: [String]
        let aiRanked: Bool
    }

    func suggestRecentFoods(
        candidates: [RecentFoodSuggestionCandidate],
        date: Date,
        likelyMeal: MealCategory
    ) async throws -> RecentFoodSuggestionResult {
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.dateFormat = "EEEE"
        let bodyCandidates: [[String: Any]] = candidates.map { candidate in
            [
                "id": candidate.id,
                "name": candidate.name,
                "brand": candidate.brand ?? "",
                "recentCount": candidate.recentCount,
                "sameWeekdayCount": candidate.sameWeekdayCount,
                "isFavorite": candidate.isFavorite,
                "lastLoggedAt": formatter.string(from: candidate.lastLoggedAt),
                "mealCounts": candidate.mealCounts,
            ]
        }
        let data = try await postRaw(
            "/v1/suggest-recent-foods",
            body: [
                "localHour": calendar.component(.hour, from: date),
                "weekday": weekdayFormatter.string(from: date),
                "likelyMeal": likelyMeal.rawValue,
                "candidates": bodyCandidates,
            ]
        )
        return try JSONDecoder().decode(RecentFoodSuggestionResult.self, from: data)
    }

    // MARK: - Photo Analysis

    struct PhotoFoodItem: Codable {
        let name: String
        let portion: String
        let grams: Double
        let calories: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let fiber: Double?
    }

    struct PhotoAnalysisResult: Codable {
        let notFood: Bool?
        let foods: [PhotoFoodItem]
    }

    struct NutritionLabelFood: Codable {
        let name: String
        let brand: String
        let servingDescription: String
        let servingGrams: Double?
        let calories: Double
        let protein: Double?
        let carbs: Double?
        let fat: Double?
        let fiber: Double?
    }

    struct NutritionLabelAnalysisResult: Codable {
        let notNutritionLabel: Bool
        let food: NutritionLabelFood?
    }

    func analyzePhoto(imageBase64: String, userMessage: String = "") async throws -> PhotoAnalysisResult {
        let body: [String: Any] = [
            "imageBase64": imageBase64,
            "userMessage": userMessage,
            "scanType": "meal",
        ]
        let data = try await postRaw("/v1/analyze-photo", body: body, timeout: 30)
        let decoded = try JSONDecoder().decode(PhotoAnalysisResult.self, from: data)
        // Server sanitizes vision output, but keep a client backstop: drop
        // items whose numbers are non-finite or absurd before any Int math.
        let safeFoods = decoded.foods.filter { food in
            food.calories.isFinite && food.calories >= 0 && food.calories <= 5000
                && food.grams.isFinite && food.grams > 0 && food.grams <= 5000
                && food.protein.isFinite && food.carbs.isFinite && food.fat.isFinite
        }
        return PhotoAnalysisResult(notFood: decoded.notFood, foods: safeFoods)
    }

    func analyzeNutritionLabel(imageBase64: String) async throws -> NutritionLabelAnalysisResult {
        let data = try await postRaw(
            "/v1/analyze-photo",
            body: [
                "imageBase64": imageBase64,
                "scanType": "nutrition_label",
            ],
            timeout: 30
        )
        let decoded = try JSONDecoder().decode(NutritionLabelAnalysisResult.self, from: data)
        guard let food = decoded.food,
              food.calories.isFinite,
              food.calories >= 0,
              food.calories <= 5_000 else {
            return NutritionLabelAnalysisResult(notNutritionLabel: true, food: nil)
        }

        let safeOptional: (Double?) -> Bool = { value in
            guard let value else { return true }
            return value.isFinite && value >= 0 && value <= 1_000
        }
        guard safeOptional(food.protein),
              safeOptional(food.carbs),
              safeOptional(food.fat),
              safeOptional(food.fiber),
              food.servingGrams.map({ $0.isFinite && $0 > 0 && $0 <= 5_000 }) ?? true else {
            return NutritionLabelAnalysisResult(notNutritionLabel: true, food: nil)
        }

        return NutritionLabelAnalysisResult(
            notNutritionLabel: decoded.notNutritionLabel,
            food: food
        )
    }

    func deleteCloudAnalytics() async throws -> Int {
        await NomvaNetworkAnalytics.shared.clear()
        guard let url = URL(string: baseURL + "/v1/privacy/analytics") else {
            throw RemoteError.badURL
        }
        let identity = NomvaCloudIdentity.current()
        let (data, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 15
            return request
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteError.serverError(http.statusCode)
        }
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return payload?["deleted"] as? Int ?? 0
    }

    // MARK: - Networking

    private func postRaw(_ path: String, body: [String: Any], timeout: TimeInterval = 15) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw RemoteError.badURL }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let identity = NomvaCloudIdentity.current()
        let (data, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            request.httpBody = bodyData
            return request
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }

        if http.statusCode == 401 {
            throw errorForAuthResponse(http.statusCode, data: data)
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteError.serverError(http.statusCode)
        }
        return data
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try await postRaw(path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Errors

    enum RemoteError: LocalizedError {
        case badURL, invalidResponse, unauthorized, serverError(Int)

        var errorDescription: String? {
            switch self {
            case .badURL:              return "Invalid API URL."
            case .invalidResponse:     return "The server returned an unexpected response."
            case .unauthorized:        return "API authentication failed."
            case .serverError(let c):  return "Server error (HTTP \(c))."
            }
        }
    }
}

// MARK: - Helpers

private extension String {
    func escapedForJSON() -> String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Nomva Cloud Identity

struct NomvaCloudIdentity: Sendable {
    let userId: String
    let deviceToken: String

    private static let userIdKey = "nomva_cloud_user_id"
    private static let deviceTokenKey = "nomva_cloud_device_token"
    private static let keychainService = "com.nomva.cloud.identity"
    private static let identityLock = NSLock()

    static func current() -> NomvaCloudIdentity {
        identityLock.lock()
        defer { identityLock.unlock() }

        let defaults = UserDefaults.standard
        let userId = persistentIdentifier(
            account: userIdKey,
            defaults: defaults
        )
        let deviceToken = persistentIdentifier(
            account: deviceTokenKey,
            defaults: defaults
        )

        return NomvaCloudIdentity(userId: userId, deviceToken: deviceToken)
    }

    private static func persistentIdentifier(
        account: String,
        defaults: UserDefaults
    ) -> String {
        if let keychainValue = NomvaCloudKeychain.loadString(
            service: keychainService,
            account: account
        ), !keychainValue.isEmpty {
            defaults.set(keychainValue, forKey: account)
            return keychainValue
        }

        let value = defaults.string(forKey: account).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()
        defaults.set(value, forKey: account)
        NomvaCloudKeychain.saveString(
            value,
            service: keychainService,
            account: account
        )
        return value
    }

    var accountKey: String {
        [userId, deviceToken].joined(separator: ":").sha256Hex
    }
}

private struct NomvaCloudSessionPayload: Codable {
    let token: String
    let expiresAt: String
    let entitlement: NomvaCloudEntitlementStatus?
}

private struct NomvaCloudEntitlementStatus: Codable {
    let status: String
    let source: String?
    let environment: String?
    let verifiedAt: String?
    let expiresAt: String?
}

private struct NomvaCloudEntitlementEvidence: Encodable, Sendable {
    let appTransactionJWS: String?
    let subscriptionTransactionJWS: String?

    static func current() async -> NomvaCloudEntitlementEvidence {
        if NomvaRuntime.isAutomatedTest {
            return NomvaCloudEntitlementEvidence(
                appTransactionJWS: nil,
                subscriptionTransactionJWS: nil
            )
        }

        async let appTransaction = currentAppTransactionJWS()
        async let subscription = currentSubscriptionTransactionJWS()
        return await NomvaCloudEntitlementEvidence(
            appTransactionJWS: appTransaction,
            subscriptionTransactionJWS: subscription
        )
    }

    private static func currentAppTransactionJWS() async -> String? {
        do {
            let result = try await AppTransaction.shared
            guard case .verified = result else { return nil }
            return result.jwsRepresentation
        } catch {
            return nil
        }
    }

    private static func currentSubscriptionTransactionJWS() async -> String? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == NomvaProduct.proMonthly,
                  transaction.revocationDate == nil,
                  transaction.isUpgraded == false,
                  transaction.expirationDate.map({ $0 > Date() }) == true else {
                continue
            }
            return result.jwsRepresentation
        }
        return nil
    }
}

private struct NomvaCloudRegistrationPayload: Encodable {
    let entitlementEvidence: NomvaCloudEntitlementEvidence
}

private struct NomvaCloudAttestationChallengePayload: Codable {
    let challenge: String
    let expiresAt: String
}

private struct NomvaCloudAppAttestEnvelope: Codable {
    let keyId: String
    let assertion: String
    let timestamp: String
}

private struct NomvaCloudServerErrorPayload: Codable {
    let error: String
    let message: String?
}

private enum NomvaCloudAuthError: LocalizedError {
    case badURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    case appAttestUnavailable
    case appAttestFailed
    case simulatorAuthDisabled
    case entitlementRequired

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Nomva Cloud auth URL is invalid."
        case .invalidResponse:
            return "Nomva Cloud auth returned an unexpected response."
        case .unauthorized:
            return "Nomva Cloud rejected the session request."
        case .serverError(let code):
            return "Nomva Cloud auth failed (HTTP \(code))."
        case .appAttestUnavailable:
            return "This device doesn't support Nomva Cloud's security requirements."
        case .appAttestFailed:
            return "Nomva Cloud couldn't verify this app installation."
        case .simulatorAuthDisabled:
            return "Nomva Cloud simulator access is disabled on this server."
        case .entitlementRequired:
            return "An active Nomva Pro subscription is required for AI features."
        }
    }
}

private enum NomvaCloudKeychain {
    static func load<T: Decodable>(service: String, account: String, as type: T.Type) -> T? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ payload: T, service: String, account: String) {
        guard let data = try? JSONEncoder().encode(payload) else { return }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func loadString(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveString(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private actor NomvaCloudAppAttestManager {
    static let shared = NomvaCloudAppAttestManager()

    private struct PendingKey {
        let id: UUID
        let task: Task<String, Error>
    }

    private let keyService = "com.nomva.cloud.appattest.key"
    private let iso8601 = ISO8601DateFormatter()
    private var pendingKeys: [String: PendingKey] = [:]

    func applyHeaders(
        to request: inout URLRequest,
        baseURL: String,
        identity: NomvaCloudIdentity,
        forceReattestation: Bool = false
    ) async throws {
        request.setValue(identity.userId, forHTTPHeaderField: "X-Nomva-User-ID")
        request.setValue(identity.deviceToken, forHTTPHeaderField: "X-Nomva-Device-Token")

        #if targetEnvironment(simulator)
        request.setValue("simulator", forHTTPHeaderField: "X-Nomva-App-Attest-Mode")
        #else
        var keyId = try await ensureAttestedKey(
            baseURL: baseURL,
            identity: identity,
            forceRefresh: forceReattestation
        )
        let timestamp = iso8601.string(from: Date())
        let payload = assertionPayload(
            for: request,
            timestamp: timestamp,
            identity: identity
        )
        let assertion: Data
        do {
            assertion = try await DCAppAttestService.shared.generateAssertionAsync(
                keyId: keyId,
                clientDataHash: payload.sha256Data
            )
        } catch {
            reset(identity: identity)
            keyId = try await ensureAttestedKey(
                baseURL: baseURL,
                identity: identity,
                forceRefresh: true
            )
            assertion = try await DCAppAttestService.shared.generateAssertionAsync(
                keyId: keyId,
                clientDataHash: payload.sha256Data
            )
        }
        let envelope = NomvaCloudAppAttestEnvelope(
            keyId: keyId,
            assertion: assertion.base64EncodedString(),
            timestamp: timestamp
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        request.setValue(envelopeData.base64EncodedString(), forHTTPHeaderField: "X-Nomva-App-Attest")
        #endif
    }

    func reset(identity: NomvaCloudIdentity) {
        NomvaCloudKeychain.delete(service: keyService, account: identity.accountKey)
    }

    private func ensureAttestedKey(
        baseURL: String,
        identity: NomvaCloudIdentity,
        forceRefresh: Bool
    ) async throws -> String {
        guard DCAppAttestService.shared.isSupported else {
            throw NomvaCloudAuthError.appAttestUnavailable
        }

        let account = identity.accountKey

        if forceRefresh, let pending = pendingKeys[account] {
            return try await pending.task.value
        }

        if forceRefresh {
            reset(identity: identity)
        }

        if let existing = NomvaCloudKeychain.loadString(
            service: keyService,
            account: account
        ), !existing.isEmpty {
            return existing
        }

        if let pending = pendingKeys[account] {
            return try await pending.task.value
        }

        let id = UUID()
        let task = Task {
            let challengePayload = try await requestChallenge(baseURL: baseURL, identity: identity)
            let keyId = try await DCAppAttestService.shared.generateKeyAsync()
            let clientDataHash = Data(SHA256.hash(data: Data(challengePayload.challenge.utf8)))
            let attestation = try await DCAppAttestService.shared.attestKeyAsync(
                keyId: keyId,
                clientDataHash: clientDataHash
            )
            try await verifyAttestation(
                baseURL: baseURL,
                identity: identity,
                keyId: keyId,
                challenge: challengePayload.challenge,
                attestation: attestation
            )
            return keyId
        }
        pendingKeys[account] = PendingKey(id: id, task: task)

        do {
            let keyId = try await task.value
            if pendingKeys[account]?.id == id {
                pendingKeys[account] = nil
            }
            NomvaCloudKeychain.saveString(keyId, service: keyService, account: account)
            return keyId
        } catch {
            if pendingKeys[account]?.id == id {
                pendingKeys[account] = nil
            }
            throw error
        }
    }

    private func requestChallenge(
        baseURL: String,
        identity: NomvaCloudIdentity
    ) async throws -> NomvaCloudAttestationChallengePayload {
        guard let url = URL(string: baseURL + "/v1/auth/challenge") else {
            throw NomvaCloudAuthError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(identity.userId, forHTTPHeaderField: "X-Nomva-User-ID")
        request.setValue(identity.deviceToken, forHTTPHeaderField: "X-Nomva-Device-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NomvaCloudAuthError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw errorForAuthResponse(http.statusCode, data: data)
        }
        guard let payload = try? JSONDecoder().decode(NomvaCloudAttestationChallengePayload.self, from: data) else {
            throw NomvaCloudAuthError.invalidResponse
        }
        return payload
    }

    private func verifyAttestation(
        baseURL: String,
        identity: NomvaCloudIdentity,
        keyId: String,
        challenge: String,
        attestation: Data
    ) async throws {
        guard let url = URL(string: baseURL + "/v1/auth/verify") else {
            throw NomvaCloudAuthError.badURL
        }

        let body: [String: Any] = [
            "challenge": challenge,
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(identity.userId, forHTTPHeaderField: "X-Nomva-User-ID")
        request.setValue(identity.deviceToken, forHTTPHeaderField: "X-Nomva-Device-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NomvaCloudAuthError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw errorForAuthResponse(http.statusCode, data: data)
        }
    }

    private func assertionPayload(
        for request: URLRequest,
        timestamp: String,
        identity: NomvaCloudIdentity
    ) -> Data {
        let body = request.httpBody ?? Data()
        let bodyHash = body.sha256Hex
        var route = request.url?.path ?? "/"
        if let query = request.url?.query, !query.isEmpty {
            route += "?\(query)"
        }

        let payload = [
            request.httpMethod ?? "GET",
            route,
            timestamp,
            identity.userId,
            identity.deviceToken.sha256Hex,
            bodyHash,
        ].joined(separator: "\n")

        return Data(payload.utf8)
    }
}

private actor NomvaCloudAuthManager {
    static let shared = NomvaCloudAuthManager()

    private struct PendingRegistration {
        let id: UUID
        let task: Task<NomvaCloudSessionPayload, Error>
    }

    private let iso8601 = ISO8601DateFormatter()
    private let sessionService = "com.nomva.cloud.session"
    private var pendingRegistrations: [String: PendingRegistration] = [:]

    func sessionToken(
        baseURL: String,
        identity: NomvaCloudIdentity,
        forceRefresh: Bool = false
    ) async throws -> String {
        let account = identity.accountKey

        if let pending = pendingRegistrations[account] {
            let payload = try await pending.task.value
            return payload.token
        }

        if !forceRefresh,
           let cached = NomvaCloudKeychain.load(
            service: sessionService,
            account: account,
            as: NomvaCloudSessionPayload.self
           ),
           !isExpired(cached.expiresAt) {
            return cached.token
        }

        if forceRefresh {
            NomvaCloudKeychain.delete(service: sessionService, account: account)
        }

        let id = UUID()
        let task = Task {
            try await registerSession(baseURL: baseURL, identity: identity)
        }
        pendingRegistrations[account] = PendingRegistration(id: id, task: task)

        do {
            let payload = try await task.value
            if pendingRegistrations[account]?.id == id {
                pendingRegistrations[account] = nil
            }
            NomvaCloudKeychain.save(payload, service: sessionService, account: account)
            return payload.token
        } catch {
            if pendingRegistrations[account]?.id == id {
                pendingRegistrations[account] = nil
            }
            throw error
        }
    }

    private func isExpired(_ expiresAt: String) -> Bool {
        guard let expiration = iso8601.date(from: expiresAt) else { return true }
        return expiration <= Date().addingTimeInterval(60)
    }

    private func registerSession(
        baseURL: String,
        identity: NomvaCloudIdentity
    ) async throws -> NomvaCloudSessionPayload {
        guard let url = URL(string: baseURL + "/v1/auth/register") else {
            throw NomvaCloudAuthError.badURL
        }
        let evidence = await NomvaCloudEntitlementEvidence.current()

        func perform(forceReattestation: Bool) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            request.httpBody = try JSONEncoder().encode(
                NomvaCloudRegistrationPayload(entitlementEvidence: evidence)
            )
            try await NomvaCloudAppAttestManager.shared.applyHeaders(
                to: &request,
                baseURL: baseURL,
                identity: identity,
                forceReattestation: forceReattestation
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NomvaCloudAuthError.invalidResponse
            }
            return (data, http)
        }

        let initial = try await perform(forceReattestation: false)
        var finalResponse = initial

        if appAttestShouldRetry(status: initial.1.statusCode, data: initial.0) {
            let freshAssertion = try await perform(forceReattestation: false)
            finalResponse = freshAssertion

            if appAttestShouldRetry(status: freshAssertion.1.statusCode, data: freshAssertion.0) {
                await NomvaCloudAppAttestManager.shared.reset(identity: identity)
                finalResponse = try await perform(forceReattestation: false)
            }
        }

        if finalResponse.1.statusCode == 401 {
            throw errorForAuthResponse(finalResponse.1.statusCode, data: finalResponse.0)
        }
        guard (200...299).contains(finalResponse.1.statusCode) else {
            throw errorForAuthResponse(finalResponse.1.statusCode, data: finalResponse.0)
        }
        guard let payload = try? JSONDecoder().decode(NomvaCloudSessionPayload.self, from: finalResponse.0) else {
            throw NomvaCloudAuthError.invalidResponse
        }
        return payload
    }

    func reset(identity: NomvaCloudIdentity) {
        NomvaCloudKeychain.delete(service: sessionService, account: identity.accountKey)
    }
}

enum NomvaCloudSessionController {
    static func invalidateCurrentSession() async {
        await NomvaCloudAuthManager.shared.reset(identity: .current())
    }
}

actor NomvaCloudAttestedRequestGate {
    static let shared = NomvaCloudAttestedRequestGate()

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        waiters.removeFirst().resume()
    }
}

// MARK: - Nomva Cloud Network Analytics

private struct NomvaNetworkAnalyticsEvent: Encodable, Sendable {
    let id: String
    let eventTime: String
    let eventType: String
    let route: String
    let method: String
    let status: Int?
    let durationMs: Double
    let bytesIn: Int?
    let bytesOut: Int?
    let success: Bool
    let errorCode: String?
    let properties: [String: String]?
}

private struct NomvaNetworkAnalyticsEnvelope: Encodable {
    let events: [NomvaNetworkAnalyticsEvent]
}

private actor NomvaNetworkAnalytics {
    static let shared = NomvaNetworkAnalytics()

    private let encoder = JSONEncoder()
    private var queue: [NomvaNetworkAnalyticsEvent] = []
    private var isFlushing = false
    private var scheduledFlush: Task<Void, Never>?

    func clear() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        queue.removeAll()
    }

    func enqueue(
        _ event: NomvaNetworkAnalyticsEvent,
        baseURL: String,
        identity: NomvaCloudIdentity
    ) {
        queue.append(event)
        if queue.count > 100 {
            queue.removeFirst(queue.count - 100)
        }

        let shouldFlushSoon = queue.count >= 5 || !event.success
        scheduleFlush(baseURL: baseURL, identity: identity, delay: shouldFlushSoon ? 0.1 : 3.0)
    }

    private func scheduleFlush(
        baseURL: String,
        identity: NomvaCloudIdentity,
        delay: TimeInterval
    ) {
        if delay > 0, scheduledFlush != nil {
            return
        }

        scheduledFlush?.cancel()
        scheduledFlush = Task(priority: .utility) { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            if nanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }
            await self?.flush(baseURL: baseURL, identity: identity)
        }
    }

    private func flush(baseURL: String, identity: NomvaCloudIdentity) async {
        guard !isFlushing, !queue.isEmpty else { return }
        guard let url = URL(string: baseURL + "/v1/analytics/events") else { return }

        scheduledFlush = nil
        isFlushing = true
        let batch = Array(queue.prefix(20))

        do {
            let body = try encoder.encode(NomvaNetworkAnalyticsEnvelope(events: batch))
            let (_, response) = try await NomvaCloudAttestedRequestGate.shared.withExclusiveAccess {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 10
                request.httpBody = body

                let token = try await NomvaCloudAuthManager.shared.sessionToken(
                    baseURL: baseURL,
                    identity: identity
                )
                try await NomvaCloudAppAttestManager.shared.applyHeaders(
                    to: &request,
                    baseURL: baseURL,
                    identity: identity
                )
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                return try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            queue.removeFirst(min(batch.count, queue.count))
        } catch {
            if queue.count > 100 {
                queue.removeFirst(queue.count - 100)
            }
        }

        isFlushing = false
        if !queue.isEmpty {
            scheduleFlush(baseURL: baseURL, identity: identity, delay: 10.0)
        }
    }
}

private func enqueueNomvaNetworkAnalytics(
    baseURL: String,
    identity: NomvaCloudIdentity,
    request: URLRequest?,
    response: URLResponse?,
    responseData: Data?,
    startedAt: Date,
    errorCode: String?
) {
    guard request?.url?.path != "/v1/analytics/events",
          request?.url?.path != "/v1/privacy/analytics" else { return }

    let http = response as? HTTPURLResponse
    let status = http?.statusCode
    let resolvedErrorCode = errorCode ?? status.flatMap { (200...399).contains($0) ? nil : "http_\($0)" }
    let success = resolvedErrorCode == nil && status.map { (200...399).contains($0) } != false
    let event = NomvaNetworkAnalyticsEvent(
        id: UUID().uuidString.lowercased(),
        eventTime: ISO8601DateFormatter().string(from: Date()),
        eventType: "client_network",
        route: request?.url?.path ?? "unknown",
        method: request?.httpMethod ?? "GET",
        status: status,
        durationMs: Date().timeIntervalSince(startedAt) * 1000,
        bytesIn: request?.httpBody?.count,
        bytesOut: responseData?.count,
        success: success,
        errorCode: resolvedErrorCode,
        properties: [
            "host": request?.url?.host ?? "",
            "transport": "urlsession",
        ]
    )

    Task(priority: .utility) {
        await NomvaNetworkAnalytics.shared.enqueue(event, baseURL: baseURL, identity: identity)
    }
}

private func analyticsErrorCode(for error: Error) -> String {
    switch error {
    case NomvaCloudAuthError.simulatorAuthDisabled:
        return "simulator_auth_disabled"
    case NomvaCloudAuthError.appAttestUnavailable:
        return "app_attest_unavailable"
    case NomvaCloudAuthError.appAttestFailed:
        return "app_attest_failed"
    case NomvaCloudAuthError.unauthorized:
        return "unauthorized"
    case NomvaCloudAuthError.entitlementRequired:
        return "entitlement_required"
    case NomvaCloudAuthError.serverError(let statusCode):
        return "auth_http_\(statusCode)"
    default:
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "url_\(nsError.code)"
        }
        return String(describing: type(of: error))
    }
}

private func sendNomvaCloudRequest(
    baseURL: String,
    identity: NomvaCloudIdentity,
    retryOnUnauthorized: Bool = true,
    buildRequest: @Sendable @escaping () throws -> URLRequest
) async throws -> (Data, URLResponse) {
    let startedAt = Date()
    var analyticsRequest: URLRequest?

    do {
        let final = try await NomvaCloudAttestedRequestGate.shared.withExclusiveAccess {
            func perform(
                forceSessionRefresh: Bool,
                forceAttestationRefresh: Bool
            ) async throws -> (Data, URLResponse, URLRequest) {
                let token = try await NomvaCloudAuthManager.shared.sessionToken(
                    baseURL: baseURL,
                    identity: identity,
                    forceRefresh: forceSessionRefresh
                )
                var request = try buildRequest()
                try await NomvaCloudAppAttestManager.shared.applyHeaders(
                    to: &request,
                    baseURL: baseURL,
                    identity: identity,
                    forceReattestation: forceAttestationRefresh
                )
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, response, request)
            }

            let initial = try await perform(
                forceSessionRefresh: false,
                forceAttestationRefresh: false
            )
            guard retryOnUnauthorized,
                  let http = initial.1 as? HTTPURLResponse,
                  http.statusCode == 401 else {
                return initial
            }

            switch serverErrorCode(from: initial.0) {
            case "invalid_session", "entitlement_refresh_required":
                return try await perform(
                    forceSessionRefresh: true,
                    forceAttestationRefresh: false
                )
            case "invalid_app_attest", "app_attest_required", "stale_app_attest":
                let freshAssertion = try await perform(
                    forceSessionRefresh: false,
                    forceAttestationRefresh: false
                )

                if let retryHTTP = freshAssertion.1 as? HTTPURLResponse,
                   appAttestShouldRetry(status: retryHTTP.statusCode, data: freshAssertion.0) {
                    await NomvaCloudAppAttestManager.shared.reset(identity: identity)
                    await NomvaCloudAuthManager.shared.reset(identity: identity)
                    return try await perform(
                        forceSessionRefresh: true,
                        forceAttestationRefresh: false
                    )
                }
                return freshAssertion
            case "simulator_auth_disabled":
                throw NomvaCloudAuthError.simulatorAuthDisabled
            default:
                return initial
            }
        }

        analyticsRequest = final.2
        enqueueNomvaNetworkAnalytics(
            baseURL: baseURL,
            identity: identity,
            request: analyticsRequest,
            response: final.1,
            responseData: final.0,
            startedAt: startedAt,
            errorCode: nil
        )
        return (final.0, final.1)
    } catch {
        let fallbackRequest = analyticsRequest ?? (try? buildRequest())
        enqueueNomvaNetworkAnalytics(
            baseURL: baseURL,
            identity: identity,
            request: fallbackRequest,
            response: nil,
            responseData: nil,
            startedAt: startedAt,
            errorCode: analyticsErrorCode(for: error)
        )
        throw error
    }
}

private func serverErrorCode(from data: Data) -> String? {
    (try? JSONDecoder().decode(NomvaCloudServerErrorPayload.self, from: data))?.error
}

private func appAttestShouldRetry(status: Int, data: Data) -> Bool {
    guard status == 401 else { return false }
    switch serverErrorCode(from: data) {
    case "invalid_attestation", "invalid_app_attest", "app_attest_required", "stale_app_attest":
        return true
    default:
        return false
    }
}

private func errorForAuthResponse(_ statusCode: Int, data: Data) -> Error {
    let errorPayload = try? JSONDecoder().decode(NomvaCloudServerErrorPayload.self, from: data)
    switch errorPayload?.error {
    case "simulator_auth_disabled":
        return NomvaCloudAuthError.simulatorAuthDisabled
    case "invalid_attestation", "invalid_app_attest", "app_attest_required", "stale_app_attest":
        return NomvaCloudAuthError.appAttestFailed
    case "invalid_session", "unauthorized":
        return NomvaCloudAuthError.unauthorized
    case "entitlement_required", "entitlement_refresh_required":
        return NomvaCloudAuthError.entitlementRequired
    default:
        if statusCode == 401 {
            return NomvaCloudAuthError.unauthorized
        }
        return NomvaCloudAuthError.serverError(statusCode)
    }
}

private extension Data {
    var sha256Data: Data {
        Data(SHA256.hash(data: self))
    }

    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var sha256Hex: String {
        Data(utf8).sha256Hex
    }
}

private extension DCAppAttestService {
    func generateKeyAsync() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            generateKey { keyId, error in
                if let keyId {
                    continuation.resume(returning: keyId)
                } else {
                    continuation.resume(throwing: error ?? NomvaCloudAuthError.appAttestFailed)
                }
            }
        }
    }

    func attestKeyAsync(keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
                if let attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: error ?? NomvaCloudAuthError.appAttestFailed)
                }
            }
        }
    }

    func generateAssertionAsync(keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
                if let assertion {
                    continuation.resume(returning: assertion)
                } else {
                    continuation.resume(throwing: error ?? NomvaCloudAuthError.appAttestFailed)
                }
            }
        }
    }
}

// MARK: - Garmin Cloud Models

struct GarminDailyActivitySummary: Codable, Equatable, Identifiable, Sendable {
    let date: String
    let activeCalories: Double
    let steps: Int?
    let totalCalories: Double?
    let updatedAt: String?

    var id: String { date }
}

struct GarminWeightSample: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let measuredAt: String
    let weightKg: Double

    var measuredDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: measuredAt) ?? ISO8601DateFormatter().date(from: measuredAt)
    }
}

private struct GarminWeightImportPayload: Codable, Sendable {
    let weights: [GarminWeightSample]
    let uploadLookbackDays: Int
    let fetchedWindows: Int
    let failedWindows: Int
    let garminWeightWriteSupported: Bool
}

struct GarminConnectionStatusPayload: Codable, Equatable, Sendable {
    let configured: Bool
    let connected: Bool
    let connectedAt: String?
    let lastWebhookAt: String?
    let garminUserIdKnown: Bool
    let averageActiveCalories: Double?
    let sampledDays: Int
    let averageWindowDays: Int?
    let averageThroughDate: String?
    let recentSummaries: [GarminDailyActivitySummary]
    let latestSummary: GarminDailyActivitySummary?

    static let empty = GarminConnectionStatusPayload(
        configured: false,
        connected: false,
        connectedAt: nil,
        lastWebhookAt: nil,
        garminUserIdKnown: false,
        averageActiveCalories: nil,
        sampledDays: 0,
        averageWindowDays: nil,
        averageThroughDate: nil,
        recentSummaries: [],
        latestSummary: nil
    )
}

private struct GarminAuthCallback {
    let status: String
    let message: String?

    init(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "error"
        message = components?.queryItems?.first(where: { $0.name == "message" })?.value
    }
}

enum GarminCloudError: LocalizedError {
    case badURL
    case invalidResponse
    case unauthorized
    case serverError(Int, String?)
    case unableToStartAuth
    case missingCallback
    case notConfigured
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Nomva couldn't build the Garmin connection URL."
        case .invalidResponse:
            return "Nomva Cloud returned an unexpected Garmin response."
        case .unauthorized:
            return "Nomva Cloud rejected the Garmin request."
        case .serverError(let statusCode, let message):
            if let message, !message.isEmpty {
                return message
            }
            return "Garmin request failed (HTTP \(statusCode))."
        case .unableToStartAuth:
            return "Nomva couldn't start the Garmin sign-in flow."
        case .missingCallback:
            return "Garmin did not return to the app."
        case .notConfigured:
            return "Garmin isn't configured on Nomva Cloud yet."
        case .cancelled:
            return "Garmin sign-in was cancelled."
        }
    }
}

// MARK: - Garmin Cloud Service

struct GarminCloudService {
    static let callbackScheme = "nomva"

    private let baseURL: String
    private let identity: NomvaCloudIdentity

    init(
        baseURL: String = NomvaAPI.baseURL,
        identity: NomvaCloudIdentity = .current()
    ) {
        self.baseURL = baseURL
        self.identity = identity
    }

    func authorizationStartURL() async throws -> URL {
        guard let url = URL(string: baseURL + "/v1/garmin/oauth/start") else {
            throw GarminCloudError.badURL
        }

        let (data, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "returnScheme": Self.callbackScheme
            ])
            return request
        }
        try validateResponse(response, data: data)

        guard
            let payload = try? JSONDecoder().decode([String: String].self, from: data),
            let raw = payload["url"],
            let authorizationURL = URL(string: raw)
        else {
            throw GarminCloudError.invalidResponse
        }
        return authorizationURL
    }

    func fetchStatus(days: Int = 45) async throws -> GarminConnectionStatusPayload {
        guard var components = URLComponents(string: baseURL + "/v1/garmin/status") else {
            throw GarminCloudError.badURL
        }
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar.current
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        components.queryItems = [
            URLQueryItem(name: "days", value: String(days)),
            URLQueryItem(name: "localDate", value: dateFormatter.string(from: .now)),
        ]
        let url = try validatedURL(from: components)

        let (data, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            return request
        }
        return try decodeStatus(from: data, response: response)
    }

    /// Ask the server to pull today's daily summary from Garmin on demand.
    @discardableResult
    func sync() async throws -> GarminConnectionStatusPayload {
        guard let url = URL(string: baseURL + "/v1/garmin/sync") else {
            throw GarminCloudError.badURL
        }

        let (data, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 20
            return request
        }
        try validateResponse(response, data: data)

        // The sync endpoint returns latestSummary + recentSummaries but not the
        // full status shape — so fetch full status afterward.
        return try await fetchStatus()
    }

    func fetchWeights(uploadLookbackDays: Int = 365) async throws -> [GarminWeightSample] {
        guard let url = URL(string: baseURL + "/v1/garmin/weights/import") else {
            throw GarminCloudError.badURL
        }

        let safeLookback = max(1, min(365, uploadLookbackDays))
        let (data, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "uploadLookbackDays": safeLookback
            ])
            request.timeoutInterval = safeLookback > 90 ? 60 : 30
            return request
        }
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(GarminWeightImportPayload.self, from: data).weights
    }

    func disconnect() async throws {
        guard let url = URL(string: baseURL + "/v1/garmin/connection") else {
            throw GarminCloudError.badURL
        }

        let (_, response) = try await sendNomvaCloudRequest(
            baseURL: baseURL,
            identity: identity
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 20
            return request
        }
        try validateResponse(response, data: nil)
    }

    private func validatedURL(from components: URLComponents) throws -> URL {
        guard let url = components.url else {
            throw GarminCloudError.badURL
        }
        return url
    }

    private func decodeStatus(from data: Data, response: URLResponse) throws -> GarminConnectionStatusPayload {
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(GarminConnectionStatusPayload.self, from: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GarminCloudError.invalidResponse
        }

        if http.statusCode == 401 {
            throw errorForAuthResponse(http.statusCode, data: data ?? Data())
        }

        guard (200...299).contains(http.statusCode) else {
            let message: String?
            if http.statusCode == 404 {
                message = "Garmin isn't deployed on Nomva Cloud yet."
            } else if http.statusCode == 503 {
                message = "Garmin is not configured on Nomva Cloud yet."
            } else if let data, let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = payload["error"] as? String {
                if error == "garmin_weight_permission_required" {
                    message = "Garmin weight access is not enabled for this connection. Reconnect Garmin, then try again."
                } else {
                    message = error.replacingOccurrences(of: "_", with: " ").capitalized
                }
            } else {
                message = nil
            }
            throw GarminCloudError.serverError(http.statusCode, message)
        }
    }
}

// MARK: - Garmin Manager

@MainActor
final class GarminManager: NSObject, ObservableObject {
    static let shared = GarminManager()

    @Published private(set) var status: GarminConnectionStatusPayload = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var hasResolvedStatus = false

    private var lastSyncAttempt: Date?
    private var authSession: ASWebAuthenticationSession?

    var isConfigured: Bool { status.configured }
    var isConnected: Bool { status.connected }
    var averageActiveCalories: Double? { status.averageActiveCalories }

    func refreshIfNeeded() async {
        guard !hasResolvedStatus else { return }
        await refresh()
    }

    func refresh(forceSync: Bool = false) async {
        guard !isLoading else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }

        do {
            let service = GarminCloudService()
            var fetched = try await service.fetchStatus()

            // If connected, decide if we should trigger a fresh sync pull from the Garmin API.
            // We sync if forced (e.g. pull-to-refresh) OR if we haven't synced in the last 5 minutes.
            if fetched.connected {
                let cooldown: TimeInterval = 300 // 5 minutes
                let timeSinceLastSync = Date().timeIntervalSince(lastSyncAttempt ?? .distantPast)
                let shouldSync = forceSync || timeSinceLastSync > cooldown

                if shouldSync {
                    lastSyncAttempt = Date()
                    if let synced = try? await service.sync() {
                        fetched = synced
                    }
                }
            }

            status = fetched
            hasResolvedStatus = true
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Force a manual sync (e.g. user tapped "Sync Now")
    func manualSync() async {
        await refresh(forceSync: true)
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastErrorMessage = nil
        defer { isConnecting = false }

        do {
            let service = GarminCloudService()
            let snapshot = try await service.fetchStatus()
            status = snapshot
            hasResolvedStatus = true

            guard snapshot.configured else {
                throw GarminCloudError.notConfigured
            }

            let callbackURL = try await startAuthenticationSession(
                url: try await service.authorizationStartURL(),
                callbackScheme: GarminCloudService.callbackScheme
            )
            let callback = GarminAuthCallback(url: callbackURL)

            guard callback.status == "success" else {
                throw GarminCloudError.serverError(400, callback.message)
            }

            await refresh()
        } catch {
            if let authError = error as? ASWebAuthenticationSessionError,
               authError.code == .canceledLogin {
                lastErrorMessage = GarminCloudError.cancelled.localizedDescription
            } else {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await GarminCloudService().disconnect()
            status = GarminConnectionStatusPayload(
                configured: status.configured,
                connected: false,
                connectedAt: nil,
                lastWebhookAt: nil,
                garminUserIdKnown: false,
                averageActiveCalories: nil,
                sampledDays: 0,
                averageWindowDays: nil,
                averageThroughDate: nil,
                recentSummaries: [],
                latestSummary: nil
            )
            hasResolvedStatus = true
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func summary(for date: Date) -> GarminDailyActivitySummary? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: date)
        return status.recentSummaries.first(where: { $0.date == key })
    }

    /// True when a sync/refresh network call is in flight.
    var isSyncing: Bool { isLoading || isConnecting }

    private func startAuthenticationSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.authSession = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: GarminCloudError.missingCallback)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session

            if !session.start() {
                authSession = nil
                continuation.resume(throwing: GarminCloudError.unableToStartAuth)
            }
        }
    }
}

extension GarminManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let window = windowScene.windows.first(where: \.isKeyWindow) {
            return window
        }

        return ASPresentationAnchor()
    }
}
