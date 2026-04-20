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

    func confirmFoodMatch(userMessage: String, foodMention: String, candidateName: String, candidateBrand: String?) async throws -> Bool {
        let prompt = "Is '\(candidateName)\(candidateBrand != nil ? " (\(candidateBrand!))" : "")' a match for '\(foodMention)'? Return 'true' or 'false'."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage)
        return completion.lowercased().contains("true")
    }

    func extractServings(userMessage: String, foodMention: String, candidateName: String, candidateServingDescription: String?) async throws -> ServingsInfo {
        let prompt = "Extract servings (Double) and portion description from '\(userMessage)' for '\(foodMention)'. Return JSON: {\"servings\": 1.0, \"portionDescription\": \"...\", \"confident\": true}"
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage, json: true)
        let data = completion.data(using: .utf8) ?? Data()
        struct Temp: Codable { let servings: Double; let portionDescription: String; let confident: Bool }
        let t = try? JSONDecoder().decode(Temp.self, from: data)
        return ServingsInfo(servings: t?.servings ?? 1.0, portionDescription: t?.portionDescription ?? "1 serving", confident: t?.confident ?? false)
    }

    func extractMeal(userMessage: String) async throws -> String? {
        let prompt = "Extract meal (breakfast, lunch, dinner, snack) or 'none'. Return just the word."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage)
        let m = completion.lowercased().trimmingCharacters(in: .whitespaces)
        return (m == "none") ? nil : m
    }

    func pickDeleteTargets(userMessage: String, logSummary: String) async throws -> [String] {
        let prompt = "Given log: \(logSummary)\nWhich food names should be deleted? Return JSON array of strings."
        let completion = try await quickComplete(prompt: prompt, userMessage: userMessage, json: true)
        let data = completion.data(using: .utf8) ?? Data()
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func estimateGrams(foodName: String, portionDescription: String) async throws -> Double {
        let prompt = "Estimate weight in grams for \(portionDescription) of \(foodName). Return just the number."
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
            print("🛑 OpenAI API Reject: \(errorText)")
            throw NSError(domain: "OpenAI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return data
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
