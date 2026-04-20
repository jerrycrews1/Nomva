import Foundation

// LlamaCppProvider is temporarily disabled.
//
// The llama.framework (StanfordBDHG/llama.cpp SPM package) must also be
// removed from the Xcode project to prevent the dyld crash on device:
//   "Library not loaded: @rpath/llama.framework/llama"
//
// To remove the package in Xcode:
//   Project navigator → select the project file → Package Dependencies tab
//   → select StanfordBDHG/llama.cpp → click the minus button → Clean Build Folder
//
// To re-enable later:
//   1. Add package: https://github.com/StanfordBDHG/llama.cpp (branch: main, product: llama)
//   2. Target build settings → C++ Interoperability Mode → C++
//   3. Restore LlamaCppProvider implementation from git history
//   4. Re-expose llama_cpp case in LLMProviderFactory.active()

final class LlamaCppProvider: LLMProvider, @unchecked Sendable {
    init(modelPath: String) {}

    func complete(
        systemPrompt: String,
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> LLMCompletion {
        throw ProviderError.disabled
    }

    func classifyIntent(
        userMessage: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> UserIntentKind {
        throw ProviderError.disabled
    }

    func splitFoods(userMessage: String) async throws -> [String] {
        throw ProviderError.disabled
    }

    func confirmFoodMatch(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateBrand: String?
    ) async throws -> Bool {
        throw ProviderError.disabled
    }

    func extractServings(
        userMessage: String,
        foodMention: String,
        candidateName: String,
        candidateServingDescription: String?
    ) async throws -> ServingsInfo {
        throw ProviderError.disabled
    }

    func extractMeal(userMessage: String) async throws -> String? {
        throw ProviderError.disabled
    }

    func pickDeleteTargets(
        userMessage: String,
        logSummary: String
    ) async throws -> [String] {
        throw ProviderError.disabled
    }

    func estimateGrams(
        foodName: String,
        portionDescription: String
    ) async throws -> Double {
        throw ProviderError.disabled
    }

    func generalReply(
        userMessage: String,
        context: String,
        recentMessages: [(role: String, content: String)]
    ) async throws -> String {
        throw ProviderError.disabled
    }

    enum ProviderError: LocalizedError {
        case disabled
        var errorDescription: String? { "llama.cpp is not enabled in this build." }
    }
}
