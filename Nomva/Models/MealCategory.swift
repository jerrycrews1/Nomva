import Foundation

enum MealCategory: String, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        }
    }

    init(storedValue: String) {
        let normalized = storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = MealCategory(rawValue: normalized) ?? .snack
    }
}
