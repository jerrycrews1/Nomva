import Foundation

enum NomvaAppGroup {
    static let identifier = "group.com.nomva.app"
}

enum NomvaWeightUnitSnapshot: String, Codable, Sendable {
    case lbs
    case kg
}

enum NomvaWidgetActivitySource: String, Codable, Sendable {
    case manual
    case appleHealth
    case garmin

    var displayName: String {
        switch self {
        case .manual:
            return "Manual"
        case .appleHealth:
            return "Apple Health"
        case .garmin:
            return "Garmin"
        }
    }
}

enum NomvaWidgetActivityState: String, Codable, Sendable {
    case manual
    case ready
    case waiting
    case setup
    case disconnected
}

enum NomvaWidgetWeightTrend: String, Codable, Sendable {
    case down
    case up
    case steady
    case unknown
}

enum NomvaWidgetRoute: String, Codable, CaseIterable, Sendable {
    case todayLog
    case hydration
    case chat
    case manualSearch
    case barcode
    case weight
    case weightLog
    case goals

    private static let scheme = "nomva"
    private static let host = "open"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "route", value: rawValue)
        ]
        return components.url ?? URL(string: "nomva://open?route=\(rawValue)")!
    }

    static func from(url: URL) -> Self? {
        guard url.scheme == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let routeValue = components?.queryItems?.first(where: { $0.name == "route" })?.value
        return routeValue.flatMap(Self.init(rawValue:))
    }
}

struct NomvaPendingHydrationEvent: Codable, Equatable, Sendable {
    var id: UUID
    var amountOz: Double
    var loggedAt: Date

    init(id: UUID = UUID(), amountOz: Double, loggedAt: Date = .now) {
        self.id = id
        self.amountOz = amountOz
        self.loggedAt = loggedAt
    }
}

struct NomvaTodayNutritionSnapshot: Codable, Equatable, Sendable {
    var consumedCalories: Double
    var adjustedGoalCalories: Double
    var remainingCalories: Double
    var mealCount: Int
    var lastLoggedAt: Date?
    var proteinG: Double
    var proteinGoalG: Double
    var carbsG: Double
    var carbsGoalG: Double
    var fatG: Double
    var fatGoalG: Double
}

struct NomvaHydrationSnapshot: Codable, Equatable, Sendable {
    var totalOz: Double
    var goalOz: Double
}

struct NomvaActivitySnapshot: Codable, Equatable, Sendable {
    var source: NomvaWidgetActivitySource
    var state: NomvaWidgetActivityState
    var activeCalories: Double?
    var averageActiveCalories: Double?
    var steps: Int?
    var goalAdjustmentCalories: Double
    var isConfigured: Bool
    var isConnected: Bool
}

struct NomvaWeightSnapshot: Codable, Equatable, Sendable {
    var latestWeightLbs: Double?
    var recentWeightsLbs: [Double]
    var sevenDayAverageLbs: Double?
    var deltaFromAverageLbs: Double?
    var lastWeighInAt: Date?
    var preferredUnit: NomvaWeightUnitSnapshot
    var trend: NomvaWidgetWeightTrend
}

struct NomvaWidgetSnapshot: Codable, Equatable, Sendable {
    var lastUpdatedAt: Date
    var today: NomvaTodayNutritionSnapshot
    var hydration: NomvaHydrationSnapshot
    var activity: NomvaActivitySnapshot
    var weight: NomvaWeightSnapshot

    static let placeholder = NomvaWidgetSnapshot(
        lastUpdatedAt: .now,
        today: NomvaTodayNutritionSnapshot(
            consumedCalories: 1420,
            adjustedGoalCalories: 2200,
            remainingCalories: 780,
            mealCount: 3,
            lastLoggedAt: Calendar.current.date(byAdding: .minute, value: -48, to: .now),
            proteinG: 108,
            proteinGoalG: 160,
            carbsG: 132,
            carbsGoalG: 210,
            fatG: 48,
            fatGoalG: 70
        ),
        hydration: NomvaHydrationSnapshot(
            totalOz: 36,
            goalOz: 64
        ),
        activity: NomvaActivitySnapshot(
            source: .garmin,
            state: .ready,
            activeCalories: 520,
            averageActiveCalories: 470,
            steps: 9211,
            goalAdjustmentCalories: 84,
            isConfigured: true,
            isConnected: true
        ),
        weight: NomvaWeightSnapshot(
            latestWeightLbs: 181.4,
            recentWeightsLbs: [182.2, 182.0, 181.8, 181.9, 181.7, 181.5, 181.4],
            sevenDayAverageLbs: 181.8,
            deltaFromAverageLbs: -0.4,
            lastWeighInAt: Calendar.current.date(byAdding: .day, value: -1, to: .now),
            preferredUnit: .lbs,
            trend: .down
        )
    )
}

enum NomvaWidgetRouteStore {
    private static let pendingRouteKey = "widget.pendingRoute"

    static func save(_ route: NomvaWidgetRoute) {
        NomvaWidgetSuite.defaults.set(route.rawValue, forKey: pendingRouteKey)
    }

    static func consume() -> NomvaWidgetRoute? {
        guard let rawValue = NomvaWidgetSuite.defaults.string(forKey: pendingRouteKey) else {
            return nil
        }
        NomvaWidgetSuite.defaults.removeObject(forKey: pendingRouteKey)
        return NomvaWidgetRoute(rawValue: rawValue)
    }
}

enum NomvaPendingHydrationStore {
    private static let pendingKey = "widget.pendingHydration"

    static func enqueue(amountOz: Double, loggedAt: Date = .now) {
        var all = read()
        all.append(NomvaPendingHydrationEvent(amountOz: amountOz, loggedAt: loggedAt))
        write(all)
    }

    static func read() -> [NomvaPendingHydrationEvent] {
        guard let data = NomvaWidgetSuite.defaults.data(forKey: pendingKey) else {
            return []
        }
        return (try? JSONDecoder().decode([NomvaPendingHydrationEvent].self, from: data)) ?? []
    }

    static func drain() -> [NomvaPendingHydrationEvent] {
        let all = read()
        NomvaWidgetSuite.defaults.removeObject(forKey: pendingKey)
        return all
    }

    private static func write(_ value: [NomvaPendingHydrationEvent]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        NomvaWidgetSuite.defaults.set(data, forKey: pendingKey)
    }
}

enum NomvaWidgetSuite {
    static var defaults: UserDefaults {
        UserDefaults(suiteName: NomvaAppGroup.identifier) ?? .standard
    }
}
