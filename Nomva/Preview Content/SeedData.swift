import Foundation
import SwiftData

@MainActor
final class SeedData {
    static func seedAppStoreData(context: ModelContext) {
        // 1. Clear existing data to ensure a clean state
        try? context.delete(model: FoodEntry.self)
        try? context.delete(model: WeightEntry.self)
        try? context.delete(model: DailyGoal.self)
        
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        
        // 2. Set realistic goals
        let goal = DailyGoal(calories: 2200, protein: 160, carbs: 200, fat: 70, fiber: 30)
        context.insert(goal)
        
        // 3. Seed Today's Log (Diverse, beautiful entries)
        let entries = [
            // Breakfast
            FoodEntry(name: "Greek Yogurt with Blueberries", brand: "Fage", meal: "breakfast", 
                      date: today.addingTimeInterval(8 * 3600), portionGrams: 200, 
                      portionDescription: "1 cup", servings: 1.0, calories: 180, 
                      proteinG: 18, carbsG: 12, fatG: 0, fiberG: 2, rawUserInput: "Preview"),
            
            FoodEntry(name: "Black Coffee", brand: nil, meal: "breakfast", 
                      date: today.addingTimeInterval(8.5 * 3600), portionGrams: 240, 
                      portionDescription: "1 cup", servings: 1.0, calories: 2, 
                      proteinG: 0, carbsG: 0, fatG: 0, fiberG: 0, rawUserInput: "Preview"),

            // Lunch
            FoodEntry(name: "Avocado Toast on Sourdough", brand: nil, meal: "lunch", 
                      date: today.addingTimeInterval(12.5 * 3600), portionGrams: 150, 
                      portionDescription: "2 slices", servings: 1.0, calories: 340, 
                      proteinG: 10, carbsG: 45, fatG: 18, fiberG: 8, rawUserInput: "Preview"),
            
            FoodEntry(name: "Grilled Chicken Breast", brand: nil, meal: "lunch", 
                      date: today.addingTimeInterval(12.5 * 3600), portionGrams: 120, 
                      portionDescription: "4 oz", servings: 1.0, calories: 195, 
                      proteinG: 35, carbsG: 0, fatG: 4, fiberG: 0, rawUserInput: "Preview"),

            // Snack
            FoodEntry(name: "Almonds", brand: "Blue Diamond", meal: "snack", 
                      date: today.addingTimeInterval(15.5 * 3600), portionGrams: 28, 
                      portionDescription: "1 oz", servings: 1.0, calories: 170, 
                      proteinG: 6, carbsG: 6, fatG: 14, fiberG: 3, rawUserInput: "Preview"),

            // Dinner
            FoodEntry(name: "Grilled Salmon Fillet", brand: nil, meal: "dinner", 
                      date: today.addingTimeInterval(19 * 3600), portionGrams: 170, 
                      portionDescription: "6 oz", servings: 1.0, calories: 350, 
                      proteinG: 38, carbsG: 0, fatG: 20, fiberG: 0, rawUserInput: "Preview"),
            
            FoodEntry(name: "Steamed Broccoli", brand: nil, meal: "dinner", 
                      date: today.addingTimeInterval(19 * 3600), portionGrams: 150, 
                      portionDescription: "1.5 cups", servings: 1.5, calories: 85, 
                      proteinG: 4, carbsG: 12, fatG: 1, fiberG: 6, rawUserInput: "Preview"),
            
            FoodEntry(name: "Quinoa", brand: nil, meal: "dinner", 
                      date: today.addingTimeInterval(19 * 3600), portionGrams: 185, 
                      portionDescription: "1 cup", servings: 1.0, calories: 220, 
                      proteinG: 8, carbsG: 39, fatG: 4, fiberG: 5, rawUserInput: "Preview")
        ]
        
        for entry in entries { context.insert(entry) }
        
        // 4. Seed Weight History (A realistic downward trend)
        let baseWeight = 182.4
        for i in 0..<14 {
            let date = cal.date(byAdding: .day, value: -i, to: today)!
            // Slight fluctuations but trending down
            let weight = baseWeight + (Double(i) * 0.2) + Double.random(in: -0.3...0.3)
            context.insert(WeightEntry(date: date, weightLbs: weight))
        }
        
        // 5. Seed a few Chat Messages for the Chat screen
        let chatMessages = [
            ChatMessage(role: "user", content: "For lunch I had avocado toast on sourdough and 4oz of grilled chicken breast."),
            ChatMessage(role: "assistant", content: "Got it! I've logged that as 535 calories. You've had 1,470 calories today, leaving you with 730 calories for dinner.")
        ]
        // Ensure they are marked for today
        for msg in chatMessages {
            msg.timestamp = today.addingTimeInterval(12.6 * 3600)
            context.insert(msg)
        }
        
        try? context.save()
    }
}
