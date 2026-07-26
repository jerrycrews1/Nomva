import Darwin
import Foundation

@main
private struct MealCategoryTests {
    private static var passed = 0
    private static var failed = 0

    static func main() {
        expect(
            MealCategory.allCases == [.breakfast, .lunch, .dinner, .snack],
            "meal destinations use the expected display order"
        )
        expect(MealCategory.breakfast.title == "Breakfast", "breakfast has a user-facing title")
        expect(MealCategory.lunch.title == "Lunch", "lunch has a user-facing title")
        expect(MealCategory.dinner.title == "Dinner", "dinner has a user-facing title")
        expect(MealCategory.snack.title == "Snack", "snack has a user-facing title")
        expect(MealCategory(storedValue: "breakfast") == .breakfast, "stored breakfast is preserved")
        expect(MealCategory(storedValue: " Lunch ") == .lunch, "stored values are normalized")
        expect(MealCategory(storedValue: "DINNER") == .dinner, "stored values are case insensitive")
        expect(MealCategory(storedValue: "snack") == .snack, "stored snack is preserved")
        expect(MealCategory(storedValue: "unknown") == .snack, "unknown legacy values remain visible")

        print("Meal category tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passed += 1
            print("PASS: \(name)")
        } else {
            failed += 1
            print("FAIL: \(name)")
        }
    }
}
