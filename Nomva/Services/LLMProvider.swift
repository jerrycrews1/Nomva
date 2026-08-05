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
    case moveFood = "move_food"
    case queryData = "query_data"
    case logWeight = "log_weight"
    case logWater = "log_water"
    case setGoal = "set_goal"
    case reply = "reply"
}

struct ServingsInfo: Sendable {
    let servings: Double
    let portionDescription: String
    let servingUnit: String
    let confident: Bool
    let hasExplicitPortion: Bool
}

struct FoodChoiceOption: Sendable {
    let name: String
    let brand: String?
    let servingDescription: String?
    let caloriesPerServing: Double
    let source: String?
    let portionBasis: String
}

struct FoodCandidateValidation: Sendable {
    let keepCurrentCandidate: Bool
    let servings: Double
    let portionDescription: String
    let servingUnit: String
    let confident: Bool
    let hasExplicitPortion: Bool
    let replacementSearchQuery: String?
}

struct EditTargetSelection: Sendable {
    let foodName: String?
    let clarificationQuestion: String?
}

struct EditResolution: Sendable {
    let servings: Double
    let portionDescription: String
    let servingUnit: String
    let confident: Bool
    let hasExplicitPortion: Bool
    let clarificationQuestion: String?
    let replacementSearchQuery: String?
}

struct WaterMutation: Sendable {
    let action: String
    let amountOz: Double?
}

struct WeightMutation: Sendable {
    let action: String
    let weightLbs: Double?
    let dateHint: String?
}

struct FoodMoveMutation: Sendable {
    let foodName: String?
    let destinationMeal: String?
    let clarificationQuestion: String?
    var moveAll: Bool = false
    var sourceMeal: String? = nil
}

struct GoalChange: Sendable {
    let metric: String
    let operation: String
    let value: Double
}

struct DataQuerySpec: Sendable {
    let metric: String
    let aggregation: String
    let window: String
    let days: Int?
}

struct ResolvedFoodCandidate: Sendable {
    let candidateId: String
    let name: String
    let brand: String?
    let source: String?
    let servings: Double
    let portionDescription: String
    let servingUnit: String
    let confident: Bool
    let hasExplicitPortion: Bool
    let servingGrams: Double?
    let servingDescription: String?
    let caloriesPerServing: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let sodiumMg: Double?
    let portionBasis: String?
    let quality: String?
    let confidence: Double?
    let sourceURL: String?
    let sourceTitle: String?
    let evidence: String?
}

/// One round of the find-food agent loop: the search query the LLM asked us
/// to run, and the candidates that came back from the on-device DB.
struct FindFoodHistoryRound: Sendable {
    let query: String
    let candidates: [FoodChoiceOption]
}

/// Decision the LLM agent makes on each turn of the find-food loop.
enum FindFoodStep: Sendable {
    /// Run another DB search with this query.
    case search(query: String)
    /// Pick a candidate from a prior round, with serving info attached.
    case pick(round: Int, candidateIndex: Int, servingsInfo: ServingsInfo)
    /// Nothing in the database is a fit — give up after exhausting attempts.
    case giveUp
}

enum FindFoodStepError: Error, Equatable, Sendable {
    case unsupported
    case invalidResponse
}

enum ResolveFoodCandidateError: Error, Equatable, Sendable {
    case unsupported
    case noMatch
    case invalidResponse
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

    /// Normalize the user's wording into a search query that best matches
    /// the food database. This lets the model decide when a restaurant/menu
    /// item should stay branded versus when a generic scalable food is better.
    func buildFoodSearchQuery(
        userMessage: String,
        foodMention: String
    ) async throws -> String

    /// End-to-end food resolution. Providers that support a richer retrieval
    /// loop can return the chosen candidate ID plus portion info directly.
    func resolveFoodCandidate(
        userMessage: String,
        foodMention: String
    ) async throws -> ResolvedFoodCandidate

    /// Pick the best candidate from a short list of database results.
    /// Returns a zero-based index into `candidates`, or nil when none fit.
    func chooseFoodCandidate(
        userMessage: String,
        foodMention: String,
        candidates: [FoodChoiceOption]
    ) async throws -> Int?

    /// Review the chosen candidate against the user's stated amount.
    /// This lets the model catch cases where a fixed menu item does not fit
    /// a small partial count like "3 nuggets" or "5 fries".
    func validateFoodCandidate(
        userMessage: String,
        foodMention: String,
        searchQuery: String,
        candidate: FoodChoiceOption,
        servingsInfo: ServingsInfo
    ) async throws -> FoodCandidateValidation

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

    /// Parse water CRUD from natural language.
    func extractWaterMutation(userMessage: String) async throws -> WaterMutation

    /// Parse weight CRUD from natural language.
    func extractWeightMutation(userMessage: String) async throws -> WeightMutation

    /// Parse a request to move one existing food entry to another meal.
    func extractFoodMove(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> FoodMoveMutation

    /// Given today's log + the user's delete request, return exact food
    /// names from the log that should be deleted.
    func pickDeleteTargets(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> [String]

    /// Identify which existing log entry the user is trying to edit.
    /// Returns an exact food name from the log when possible, otherwise a
    /// model-authored clarification question.
    func pickEditTarget(
        userMessage: String,
        logSummary: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> EditTargetSelection

    /// Interpret a correction against a currently logged food item.
    /// The model can ask for clarification or provide a normalized query for
    /// replacement when the current item is too specific to resize directly.
    func resolveEditRequest(
        userMessage: String,
        currentEntryName: String,
        currentEntryBrand: String?,
        currentPortionDescription: String
    ) async throws -> EditResolution

    /// Estimate the total grams for a described portion of a food.
    /// E.g. "2 slices" of bacon → ~24 g. Uses the model's world knowledge
    /// rather than a hardcoded table.
    func estimateGrams(
        foodName: String,
        portionDescription: String,
        referenceServingDescription: String?,
        referenceServingGrams: Double?
    ) async throws -> Double

    /// Produce a conversational reply using provided context.
    func generalReply(
        userMessage: String,
        context: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> String

    /// Run one turn of the find-food agent loop. Given the user's message,
    /// the food mention being resolved, and a history of (query, candidates)
    /// rounds the client has already executed, the LLM either asks for
    /// another DB search, picks a candidate (with portion info attached),
    /// or gives up. Providers that don't support this should throw
    /// `FindFoodStepError.unsupported`; the caller will fall back to the
    /// legacy chooseCandidate + validate chain.
    func findFoodStep(
        userMessage: String,
        foodMention: String,
        history: [FindFoodHistoryRound]
    ) async throws -> FindFoodStep
}

extension LLMProvider {
    /// Default: not supported. Providers that can resolve against the server
    /// DB override this; callers should fall back to the local resolver.
    func resolveFoodCandidate(
        userMessage _: String,
        foodMention _: String
    ) async throws -> ResolvedFoodCandidate {
        throw ResolveFoodCandidateError.unsupported
    }

    /// Default: not supported. Providers that can run the agent loop override.
    func findFoodStep(
        userMessage _: String,
        foodMention _: String,
        history _: [FindFoodHistoryRound]
    ) async throws -> FindFoodStep {
        throw FindFoodStepError.unsupported
    }

    func extractWaterMutation(userMessage _: String) async throws -> WaterMutation {
        throw FindFoodStepError.unsupported
    }

    func extractWeightMutation(userMessage _: String) async throws -> WeightMutation {
        throw FindFoodStepError.unsupported
    }

    func extractFoodMove(
        userMessage _: String,
        logSummary _: String,
        recentMessages _: [(role: String, content: String)]
    ) async throws -> FoodMoveMutation {
        throw FindFoodStepError.unsupported
    }
}

// MARK: - API Configuration

enum NomvaAPI {
    static let baseURL = "https://nomva.nerdquad.com"
}

// MARK: - Factory

enum LLMProviderFactory {
    /// Returns the active provider - always Nomva Cloud using task-specific GPT-5 models.
    @MainActor
    static func active() -> any LLMProvider {
        return RemoteAPIProvider(
            baseURL: NomvaAPI.baseURL
        )
    }
}
