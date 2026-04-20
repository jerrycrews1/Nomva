import Foundation

// MARK: - Provider Protocol

struct LLMCompletion: Sendable {
    let text: String
    let providerType: String
    let usedFallback: Bool
}

// MARK: - Focused task types
//
// The on-device model produces much better output when asked ONE small question
// at a time with a tiny schema rather than one giant struct with 20+ fields.
// These focused types back each step of the chat pipeline.

enum UserIntentKind: String, Sendable {
    case logFood = "log_food"
    case deleteFood = "delete_food"
    case editFood = "edit_food"
    case queryData = "query_data"
    case logWeight = "log_weight"
    case setGoal = "set_goal"
    case reply = "reply"
}

struct ServingsInfo: Sendable {
    let servings: Double
    let portionDescription: String
    let confident: Bool
}

/// Abstracts the underlying LLM backend. `complete` is the general-purpose
/// JSON-returning method kept for the legacy agentic loop. The focused
/// methods (classifyIntent, splitFoods, etc.) drive the new step-by-step
/// chat pipeline with tiny prompts + tiny generable structs.
protocol LLMProvider: Sendable {
    func complete(
        systemPrompt: String,
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> LLMCompletion

    /// Classify what the user is trying to do.
    func classifyIntent(
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> UserIntentKind

    /// Return the distinct food mentions in the message, e.g.
    /// "eggs and toast with OJ" → ["eggs", "toast", "orange juice"].
    /// If there's only one food, returns a single-element array.
    func splitFoods(userMessage: String) async throws -> [String]

    /// Given the user's original message and a candidate food name,
    /// decide whether that candidate is what the user meant.
    func confirmFoodMatch(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateBrand: String?
    ) async throws -> Bool

    /// Extract how many servings + a human-readable portion description.
    func extractServings(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateServingDescription: String?
    ) async throws -> ServingsInfo

    /// Extract which meal the user mentioned (breakfast/lunch/dinner/snack),
    /// or nil if the user didn't say.
    func extractMeal(userMessage: String) async throws -> String?

    /// Given today's log + the user's delete request, return exact food
    /// names from the log that should be deleted.
    func pickDeleteTargets(
        userMessage: String,
        logSummary: String
    ) async throws -> [String]

    /// Estimate the total grams for a described portion of a food.
    /// E.g. "2 slices" of bacon → ~24 g. Uses the model's world knowledge
    /// rather than a hardcoded table.
    func estimateGrams(
        foodName: String,
        portionDescription: String
    ) async throws -> Double

    /// Produce a conversational reply using provided context.
    func generalReply(
        userMessage: String,
        context: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> String
}

// MARK: - API Configuration

enum NomvaAPI {
    static let baseURL = "https://nomva.nerdquad.com"
    /// Shared app secret — all authenticated app installs use this.
    static let appSecret = "nomva-app-2026"
    /// Dev secret for the developer account — bypasses subscription checks.
    static let devSecret = "nomva-dev-jerry-2026"
}

// MARK: - Factory

enum LLMProviderFactory {
    /// Returns the active provider — always Nomva Cloud (GPT-4o-mini).
    @MainActor
    static func active() -> any LLMProvider {
        let isDev = UserDefaults.standard.bool(forKey: "is_premium_dev_override")
        let secret = isDev ? NomvaAPI.devSecret : NomvaAPI.appSecret
        return RemoteAPIProvider(
            baseURL: NomvaAPI.baseURL,
            apiSecret: secret
        )
    }
}
