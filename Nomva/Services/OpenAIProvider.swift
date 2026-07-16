import Foundation

struct OpenAIProvider: LLMProvider {
    let apiKey: String
    private let model = "gpt-4o-mini"

    // MARK: - Core Completion

    func complete(
        systemPrompt: String,
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> LLMCompletion {
        guard !apiKey.isEmpty else {
            return LLMCompletion(text: "{\"action\":\"reply\",\"text\":\"OpenAI API Key is missing. Add it in Settings.\"}", providerType: "openai", usedFallback: false)
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in recentMessages {
            messages.append(["role": msg.role, "content": msg.content])
        }
        messages.append(["role": "user", "content": userMessage])

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "response_format": ["type": "json_object"],
            "temperature": 0.0
        ]

        do {
            let data = try await postToOpenAI(payload)
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let text = response.choices.first?.message.content ?? "{}"

            return LLMCompletion(
                text: text,
                providerType: "openai",
                usedFallback: false
            )
        } catch {
            print("❌ OpenAI Error: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Focused Tasks (GPT-4o-mini handles these via prompts)

    func classifyIntent(userMessage: String, recentMessages: [(role: String, content: String)]) async throws -> UserIntentKind {
        let prompt = "Classify user intent into one: log_food, delete_food, edit_food, query_data, log_weight, set_goal, reply. Return just the word."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage)
        return UserIntentKind(rawValue: completion.lowercased()) ?? .reply
    }

    func splitFoods(userMessage: String) async throws -> [String] {
        let prompt = "List distinct foods in the message as a JSON array of strings. Example: [\"eggs\", \"bacon\"]. Return JSON only."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage, json: true)
        let data = completion.data(using: .utf8) ?? Data()
        return (try? JSONDecoder().decode([String].self, from: data)) ?? [userMessage]
    }

    func buildFoodSearchQuery(userMessage: String, foodMention: String) async throws -> String {
        let prompt = """
        Turn the food mention into the best short search query for a nutrition database.
        The amount in the food mention matters.
        Keep exact restaurant/menu wording only when the user clearly specified that exact size or count and wants that exact menu item.
        When the user gave a loose partial amount like "5 Chick-fil-A fries" or "3 Chick-fil-A nuggets", prefer the underlying scalable food like "waffle fries" or "chicken nuggets" instead of a whole menu item.
        For plain whole foods, prefer the everyday whole-food form rather than a subpart or oversized prepared entry. Example: "1 egg" should search "whole egg", not "egg white".
        Return JSON only: {"query":"..."}
        """
        let completion = try await quickComplete(
            prompt: prompt,
            userMessage: "User said: \(userMessage)\nFood mention: \(foodMention)",
            json: true
        )
        let data = completion.data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? foodMention
    }

    func chooseFoodCandidate(
        userMessage: String,
        foodMention: String,
        candidates: [FoodChoiceOption]
    ) async throws -> Int? {
        let lines = candidates.enumerated().map { index, candidate in
            let brand = candidate.brand.map { " | brand: \($0)" } ?? ""
            let serving = candidate.servingDescription.map { " | serving: \($0)" } ?? ""
            let source = candidate.source.map { " | source: \($0)" } ?? ""
            return "\(index): \(candidate.name)\(brand)\(serving)\(source) | basis: \(candidate.portionBasis) | calories: \(Int(candidate.caloriesPerServing.rounded()))"
        }.joined(separator: "\n")
        let prompt = """
        Pick the best candidate for the user's food mention.
        If the user described a partial amount, prefer the candidate that best supports that portion realistically.
        Favor gram-scalable candidates for loose partial amounts when the alternatives are fixed whole servings.
        Reject menu-size candidates when the size or count clearly conflicts with the user's amount.
        Reject candidates that introduce unrelated concepts the user did not mention, such as salad, dressing, kids meal, egg white, or a menu size like medium/large.
        Return JSON only: {"candidateIndex": 0} or {"candidateIndex": null}
        """
        let completion = try await quickComplete(
            prompt: prompt,
            userMessage: "User said: \(userMessage)\nFood mention: \(foodMention)\nCandidates:\n\(lines)",
            json: true
        )
        let data = completion.data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["candidateIndex"] as? Int
    }

    func validateFoodCandidate(
        userMessage: String,
        foodMention: String,
        searchQuery: String,
        candidate: FoodChoiceOption,
        servingsInfo: ServingsInfo
    ) async throws -> FoodCandidateValidation {
        let brand = candidate.brand.map { "\nCandidate brand: \($0)" } ?? ""
        let serving = candidate.servingDescription.map { "\nCandidate serving: \($0)" } ?? ""
        let source = candidate.source.map { "\nCandidate source: \($0)" } ?? ""
        let prompt = """
        Review whether the selected nutrition database candidate is a realistic basis for the user's portion.
        The original food mention is the source of truth for the amount.
        If the extracted portion lost an explicit count or size from the food mention, correct it.
        If the selected candidate introduces an unrelated subpart or meal context the user did not mention, reject it and provide a better replacementSearchQuery.
        If the user gave a vague amount like "some spinach", convert it into a natural everyday portion such as "1 cup" instead of leaving a synthetic "1 serving".
        If the candidate is a fixed whole serving or menu item that does not fit the user's small partial amount, reject it and provide a more neutral scalable replacementSearchQuery.
        Keep restaurant/menu candidates only when the user's amount actually matches that exact item size or count.
        Also return servingUnit as a reusable base unit in singular form when natural, such as "nugget", "fry", "egg", "slice", "cup", or "serving".
        Return JSON only with keys: keepCurrentCandidate, servings, portionDescription, servingUnit, confident, hasExplicitPortion, replacementSearchQuery.
        """
        let completion = try await quickComplete(
            prompt: prompt,
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
            json: true
        )
        let data = completion.data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return FoodCandidateValidation(
            keepCurrentCandidate: json["keepCurrentCandidate"] as? Bool ?? true,
            servings: json["servings"] as? Double ?? servingsInfo.servings,
            portionDescription: json["portionDescription"] as? String ?? servingsInfo.portionDescription,
            servingUnit: (json["servingUnit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? servingsInfo.servingUnit,
            confident: json["confident"] as? Bool ?? servingsInfo.confident,
            hasExplicitPortion: json["hasExplicitPortion"] as? Bool ?? servingsInfo.hasExplicitPortion,
            replacementSearchQuery: (json["replacementSearchQuery"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    func confirmFoodMatch(userMessage: String, foodMention: String, candidateName: String, candidateBrand: String?) async throws -> Bool {
        let prompt = "Is '\(candidateName)\(candidateBrand != nil ? " (\(candidateBrand!))" : "")' a match for '\(foodMention)'? Return 'true' or 'false'."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage)
        return completion.lowercased().contains("true")
    }

    func extractServings(userMessage: String, foodMention: String, candidateName: String, candidateServingDescription: String?) async throws -> ServingsInfo {
        let prompt = """
        Extract servings (Double), portion description, a reusable servingUnit, confidence, and whether the user explicitly stated a usable portion from "\(userMessage)" for "\(foodMention)".
        Focus only on this food mention and do not borrow counts from other foods in the same message.
        Do not invent a replacement amount for vague objections.
        Examples:
        - "I had three Chick-fil-A nuggets, one egg, and about 5 Chick-fil-A fries" for "three Chick-fil-A nuggets" -> {"servings": 3, "portionDescription": "3 nuggets", "servingUnit": "nugget", "confident": true, "hasExplicitPortion": true}
        - "I had 3 nuggets, 1 egg, and about 5 fries" for "about 5 fries" -> {"servings": 5, "portionDescription": "5 fries", "servingUnit": "fry", "confident": true, "hasExplicitPortion": true}
        - "some spinach" -> {"servings": 1, "portionDescription": "1 cup", "servingUnit": "cup", "confident": false, "hasExplicitPortion": false}
        - "It was only about 5 fries" -> {"servings": 5, "portionDescription": "5 fries", "servingUnit": "fry", "confident": true, "hasExplicitPortion": true}
        - "That's not right..." -> {"servings": 1, "portionDescription": "1 serving", "servingUnit": "serving", "confident": false, "hasExplicitPortion": false}
        Return JSON: {"servings": 1.0, "portionDescription": "...", "servingUnit": "serving", "confident": true, "hasExplicitPortion": true}
        """
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage, json: true)
        let data = completion.data(using: .utf8) ?? Data()
        struct Temp: Codable {
            let servings: Double
            let portionDescription: String
            let servingUnit: String?
            let confident: Bool
            let hasExplicitPortion: Bool?
        }
        let t = try? JSONDecoder().decode(Temp.self, from: data)
        return ServingsInfo(
            servings: t?.servings ?? 1.0,
            portionDescription: t?.portionDescription ?? "1 serving",
            servingUnit: t?.servingUnit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "serving",
            confident: t?.confident ?? false,
            hasExplicitPortion: t?.hasExplicitPortion ?? false
        )
    }

    func extractMeal(userMessage: String) async throws -> String? {
        let prompt = "Extract meal (breakfast, lunch, dinner, snack) or 'none'. Return just the word."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage)
        let m = completion.lowercased().trimmingCharacters(in: .whitespaces)
        return (m == "none") ? nil : m
    }

    func pickDeleteTargets(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> [String] {
        let history = recentMessages.suffix(4)
            .map { "\($0.role.capitalized): \($0.content)" }
            .joined(separator: "\n")
        let prompt = "Given recent conversation and log, which exact food names should be deleted? For pronouns like that/it, use the most recently referenced logged food. Return JSON array of strings."
        let completion = try await quickComplete(prompt: prompt, userMessage: "Recent conversation:\n\(history)\n\nFood log:\n\(logSummary)\n\nUser said: \(userMessage)", json: true)
        let data = completion.data(using: .utf8) ?? Data()
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func pickEditTarget(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> EditTargetSelection {
        let history = recentMessages.suffix(4)
            .map { "\($0.role.capitalized): \($0.content)" }
            .joined(separator: "\n")
        let prompt = """
        Pick the exact food name from the log that the user wants to edit.
        Use recent conversation context when the user says things like "that's not right" or "actually".
        If you cannot identify one entry confidently, ask a short clarification question.
        Return JSON only: {"foodName":"...", "clarificationQuestion":null}
        """
        let completion = try await quickComplete(
            prompt: prompt,
            userMessage: "Recent conversation:\n\(history)\n\nFood log:\n\(logSummary)\n\nUser said: \(userMessage)",
            json: true
        )
        let data = completion.data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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
        let brandLine = currentEntryBrand.map { "\nCurrent brand: \($0)" } ?? ""
        let prompt = """
        Interpret the user's correction for the currently logged food.
        If the user did not provide a concrete replacement amount, set hasExplicitPortion to false and ask a short follow-up question.
        If the current logged food is too specific to resize directly, provide a neutral replacementSearchQuery such as "chicken nuggets" or "waffle fries".
        Also return servingUnit as a reusable base unit in singular form when natural, such as "nugget", "fry", "egg", "slice", "cup", or "serving".
        Return JSON only with keys: servings, portionDescription, servingUnit, confident, hasExplicitPortion, clarificationQuestion, replacementSearchQuery.
        """
        let completion = try await quickComplete(
            prompt: prompt,
            userMessage: "Current entry: \(currentEntryName)\(brandLine)\nCurrent portion: \(currentPortionDescription)\nUser said: \(userMessage)",
            json: true
        )
        let data = completion.data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return EditResolution(
            servings: json["servings"] as? Double ?? 1,
            portionDescription: json["portionDescription"] as? String ?? "1 serving",
            servingUnit: (json["servingUnit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "serving",
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
        var prompt = "Estimate weight in grams for \(portionDescription) of \(foodName). If a reference serving is provided, anchor the estimate to that serving for subsets like 5 fries or 3 nuggets. Return just the number."
        if let referenceServingDescription, let referenceServingGrams {
            prompt += " Reference serving: \(referenceServingDescription) is about \(referenceServingGrams) grams."
        }
        let completion = try await quickComplete(prompt: prompt, userMessage: "")
        return Double(completion.filter { $0.isNumber || $0 == "." }) ?? 100.0
    }

    func generalReply(userMessage: String, context: String, recentMessages: [(role: String, content: String)]) async throws -> String {
        let prompt = "You are Nomva, a nutrition coach. Context: \(context). Answer concisely."
        return try await quickComplete(prompt: prompt, userMessage: userMessage)
    }

    // MARK: - Networking

    private func quickComplete(prompt: String, userMessage: String, json: Bool = false) async throws -> String {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": userMessage]
            ],
            "response_format": ["type": json ? "json_object" : "text"],
            "temperature": 0.0
        ]
        let data = try await postToOpenAI(payload)
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }

    private func postToOpenAI(_ payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return data
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - OpenAI Response Models

struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}
