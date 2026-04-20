import Foundation
import AuthenticationServices
import Combine
import UIKit

/// Calls the Nomva API server (Node.js on Lightsail) which proxies to GPT-4o-mini.
/// Each method mirrors the focused LLMProvider protocol — one tiny call per step.
/// Used as a fallback when Apple Foundation Models aren't available or misbehave.
struct RemoteAPIProvider: LLMProvider {

    // MARK: - Configuration

    /// Base URL of the Nomva API server (no trailing slash).
    /// In production: "https://nomva.nerdquad.com"
    private let baseURL: String
    private let apiSecret: String?

    init(
        baseURL: String = "https://nomva.nerdquad.com",
        apiSecret: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiSecret = apiSecret
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
            servings: json["servings"] as? Double ?? 1,
            portionDescription: json["portionDescription"] as? String ?? "1 serving",
            confident: json["confident"] as? Bool ?? false
        )
    }

    func extractMeal(userMessage: String) async throws -> String? {
        let body: [String: Any] = ["userMessage": userMessage]
        let result: [String: String?] = try await post("/v1/extract-meal", body: body)
        return result["meal"] ?? nil
    }

    func pickDeleteTargets(
        userMessage: String,
        logSummary: String
    ) async throws -> [String] {
        let body: [String: Any] = [
            "userMessage": userMessage,
            "logSummary": logSummary
        ]
        let result: [String: [String]] = try await post("/v1/pick-delete-targets", body: body)
        return result["foodNames"] ?? []
    }

    func estimateGrams(
        foodName: String,
        portionDescription: String
    ) async throws -> Double {
        let body: [String: Any] = [
            "foodName": foodName,
            "portionDescription": portionDescription
        ]
        let data = try await postRaw("/v1/estimate-grams", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let grams = json["grams"] as? Double, grams > 0 else {
            throw RemoteError.invalidResponse
        }
        return grams
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

    func extractGoal(userMessage: String) async throws -> (calories: Double?, protein: Double?, carbs: Double?, fat: Double?, fiber: Double?) {
        let body: [String: Any] = ["userMessage": userMessage]
        let data = try await postRaw("/v1/extract-goal", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (
            calories: json["calories"] as? Double,
            protein: json["protein"] as? Double,
            carbs: json["carbs"] as? Double,
            fat: json["fat"] as? Double,
            fiber: json["fiber"] as? Double
        )
    }

    // MARK: - Networking

    private func postRaw(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw RemoteError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = apiSecret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }

        if http.statusCode == 401 { throw RemoteError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            print("⚠️ Remote API \(path) returned \(http.statusCode): \(msg)")
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

    static func current() -> NomvaCloudIdentity {
        let defaults = UserDefaults.standard

        let userId: String
        if let existing = defaults.string(forKey: userIdKey), !existing.isEmpty {
            userId = existing
        } else {
            userId = UUID().uuidString.lowercased()
            defaults.set(userId, forKey: userIdKey)
        }

        let deviceToken: String
        if let existing = defaults.string(forKey: deviceTokenKey), !existing.isEmpty {
            deviceToken = existing
        } else {
            deviceToken = UUID().uuidString.lowercased()
            defaults.set(deviceToken, forKey: deviceTokenKey)
        }

        return NomvaCloudIdentity(userId: userId, deviceToken: deviceToken)
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

struct GarminConnectionStatusPayload: Codable, Equatable, Sendable {
    let configured: Bool
    let connected: Bool
    let connectedAt: String?
    let lastWebhookAt: String?
    let garminUserIdKnown: Bool
    let averageActiveCalories: Double?
    let sampledDays: Int
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
    private let apiSecret: String
    private let identity: NomvaCloudIdentity

    init(
        baseURL: String = NomvaAPI.baseURL,
        apiSecret: String = UserDefaults.standard.bool(forKey: "is_premium_dev_override")
            ? NomvaAPI.devSecret
            : NomvaAPI.appSecret,
        identity: NomvaCloudIdentity = .current()
    ) {
        self.baseURL = baseURL
        self.apiSecret = apiSecret
        self.identity = identity
    }

    func authorizationStartURL() throws -> URL {
        guard var components = URLComponents(string: baseURL + "/garmin/oauth/start") else {
            throw GarminCloudError.badURL
        }
        components.queryItems = [
            URLQueryItem(name: "nomvaUserId", value: identity.userId),
            URLQueryItem(name: "deviceToken", value: identity.deviceToken),
            URLQueryItem(name: "returnScheme", value: Self.callbackScheme),
        ]

        guard let url = components.url else {
            throw GarminCloudError.badURL
        }
        return url
    }

    func fetchStatus(days: Int = 45) async throws -> GarminConnectionStatusPayload {
        guard var components = URLComponents(string: baseURL + "/v1/garmin/status") else {
            throw GarminCloudError.badURL
        }
        components.queryItems = [URLQueryItem(name: "days", value: String(days))]

        var request = URLRequest(url: try validatedURL(from: components))
        request.httpMethod = "GET"
        configureHeaders(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeStatus(from: data, response: response)
    }

    /// Ask the server to pull today's daily summary from Garmin on demand.
    @discardableResult
    func sync() async throws -> GarminConnectionStatusPayload {
        guard let url = URL(string: baseURL + "/v1/garmin/sync") else {
            throw GarminCloudError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        configureHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        // The sync endpoint returns latestSummary + recentSummaries but not the
        // full status shape — so fetch full status afterward.
        return try await fetchStatus()
    }

    func disconnect() async throws {
        guard let url = URL(string: baseURL + "/v1/garmin/connection") else {
            throw GarminCloudError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        configureHeaders(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: nil)
    }

    private func configureHeaders(_ request: inout URLRequest) {
        request.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.userId, forHTTPHeaderField: "X-Nomva-User-ID")
        request.setValue(identity.deviceToken, forHTTPHeaderField: "X-Nomva-Device-Token")
        request.timeoutInterval = 20
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
            throw GarminCloudError.unauthorized
        }

        guard (200...299).contains(http.statusCode) else {
            let message: String?
            if http.statusCode == 404 {
                message = "Garmin isn't deployed on Nomva Cloud yet."
            } else if http.statusCode == 503 {
                message = "Garmin is not configured on Nomva Cloud yet."
            } else if let data, let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = payload["error"] as? String {
                message = error.replacingOccurrences(of: "_", with: " ").capitalized
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

    private var hasLoadedOnce = false
    private var lastSyncAttempt: Date?
    private var authSession: ASWebAuthenticationSession?

    var isConfigured: Bool { status.configured }
    var isConnected: Bool { status.connected }
    var averageActiveCalories: Double? { status.averageActiveCalories }

    func refreshIfNeeded() async {
        guard !hasLoadedOnce else { return }
        await refresh()
    }

    func refresh(forceSync: Bool = false) async {
        print("🌐 Garmin refresh() called | isLoading=\(isLoading) | forceSync=\(forceSync)")
        guard !isLoading else {
            print("🌐 Garmin refresh() SKIPPED — isLoading is true")
            return
        }
        isLoading = true
        defer {
            isLoading = false
            print("🌐 Garmin refresh() done | isLoading=false")
        }

        do {
            let service = GarminCloudService()
            print("🌐 Garmin refresh() → fetchStatus...")
            var fetched = try await service.fetchStatus()
            print("🌐 Garmin refresh() fetchStatus ✅ connected=\(fetched.connected) latest=\(fetched.latestSummary?.date ?? "nil") recentCount=\(fetched.recentSummaries.count)")

            // If connected, decide if we should trigger a fresh sync pull from the Garmin API.
            // We sync if forced (e.g. pull-to-refresh) OR if we haven't synced in the last 5 minutes.
            if fetched.connected {
                let cooldown: TimeInterval = 300 // 5 minutes
                let timeSinceLastSync = Date().timeIntervalSince(lastSyncAttempt ?? .distantPast)
                let shouldSync = forceSync || timeSinceLastSync > cooldown

                if shouldSync {
                    print("🌐 Garmin refresh() → triggering sync pull (forceSync=\(forceSync), lastSync=\(Int(timeSinceLastSync))s ago)...")
                    lastSyncAttempt = Date()
                    if let synced = try? await service.sync() {
                        print("🌐 Garmin refresh() sync ✅")
                        fetched = synced
                    } else {
                        print("🌐 Garmin refresh() sync failed (silent)")
                    }
                } else {
                    print("🌐 Garmin refresh() → skipping sync pull (cooldown active, lastSync=\(Int(timeSinceLastSync))s ago)")
                }
            }

            status = fetched
            hasLoadedOnce = true
            lastErrorMessage = nil
        } catch {
            print("🌐 Garmin refresh() ❌ error: \(error)")
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

            guard snapshot.configured else {
                throw GarminCloudError.notConfigured
            }

            let callbackURL = try await startAuthenticationSession(
                url: try service.authorizationStartURL(),
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
                recentSummaries: [],
                latestSummary: nil
            )
            hasLoadedOnce = true
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
