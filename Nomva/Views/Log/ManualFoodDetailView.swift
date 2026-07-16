import SwiftUI
import SwiftData

struct ManualFoodDetailView: View {
    let food: FoodItem
    var onLog: (() -> Void)? = nil
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var quantity: Double = 1.0
    @State private var inputMode: InputMode = .servings
    @State private var selectedMeal: String
    
    enum InputMode: String, CaseIterable {
        case servings = "Servings"
        case weight = "Weight (g)"
    }
    
    init(food: FoodItem, meal: String? = nil, onLog: (() -> Void)? = nil) {
        self.food = food
        self.onLog = onLog
        _selectedMeal = State(initialValue: meal ?? "lunch")
    }
    
    private var currentGrams: Double {
        if inputMode == .servings {
            return quantity * (food.servingGrams ?? 100)
        } else {
            return quantity
        }
    }
    
    private var nutrition: NutritionValues {
        food.scaled(to: currentGrams)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with live rings
                HStack(spacing: 20) {
                    RingView(
                        progress: 0.7, // Mock progress for visual flair
                        label: "\(Int(nutrition.calories))",
                        sublabel: "cal",
                        color: .orange,
                        size: 80
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(food.name)
                            .font(.title3.bold())
                            .lineLimit(2)
                        if let brand = food.brand {
                            Text(brand)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.systemGray6).opacity(0.5))
                
                Form {
                    Section {
                        Picker("Input Mode", selection: $inputMode) {
                            ForEach(InputMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 8)
                        .onChange(of: inputMode) { _, newValue in
                            if newValue == .weight {
                                quantity = food.servingGrams ?? 100
                            } else {
                                quantity = 1.0
                            }
                        }
                        
                        HStack(spacing: 20) {
                            Spacer()
                            
                            TextField("0", value: $quantity, format: .number)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity)
                            
                            let unitLabel: String = {
                                if inputMode == .servings {
                                    let raw = food.servingDesc?.lowercased() ?? "servings"
                                    if raw == "g" || raw == "grm" || raw == "gram" || raw == "grams" {
                                        return "servings"
                                    }
                                    return food.servingDesc ?? "servings"
                                } else {
                                    return "g"
                                }
                            }()
                                
                            Text(unitLabel)
                                .font(.title3.bold())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 16)
                    }
                    
                    Section("Quick Select") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                let servingWeight = food.servingGrams ?? 100
                                let values: [Double] = inputMode == .servings 
                                    ? [0.5, 1.0, 1.5, 2.0, 3.0, 4.0] 
                                    : [servingWeight * 0.5, servingWeight, servingWeight * 1.5, servingWeight * 2, servingWeight * 3, servingWeight * 4]
                                
                                ForEach(values, id: \.self) { val in
                                    Button {
                                        quantity = val
                                    } label: {
                                        Text(inputMode == .servings ? formatServing(val) : "\(Int(val))g")
                                            .font(.subheadline.bold())
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(quantity == val ? Color.orange : Color(.systemGray5))
                                            .foregroundColor(quantity == val ? .white : .primary)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    Section("Meal Time") {
                        Picker("Select Meal", selection: $selectedMeal) {
                            Label("Breakfast", systemImage: "sun.and.horizon").tag("breakfast")
                            Label("Lunch", systemImage: "sun.max").tag("lunch")
                            Label("Dinner", systemImage: "moon").tag("dinner")
                            Label("Snack", systemImage: "leaf").tag("snack")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    
                    Section("Nutrition Facts") {
                        HStack(spacing: 0) {
                            macroCard(label: "Protein", val: nutrition.protein, color: .blue)
                            Divider()
                            macroCard(label: "Carbs", val: nutrition.carbs, color: .green)
                            Divider()
                            macroCard(label: "Fat", val: nutrition.fat, color: .yellow)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log It") { saveEntry() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .fontWeight(.bold)
                }
            }
        }
    }
    
    private func macroCard(label: String, val: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            Text("\(Int(val))g")
                .font(.headline.monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
    
    private func formatServing(_ val: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: val)) ?? "\(val)"
    }
    
    private func saveEntry() {
        let totalGrams = currentGrams
        let nut = food.scaled(to: totalGrams)
        let per100 = food.per100g
        
        let displayPortion = inputMode == .servings 
            ? "\(quantity.formatted()) \(food.servingDesc ?? "serving")"
            : "\(Int(quantity))g"

        let entry = FoodEntry(
            name: food.name,
            brand: food.brand,
            meal: selectedMeal,
            portionGrams: totalGrams,
            portionDescription: displayPortion,
            servings: inputMode == .servings ? quantity : (quantity / (food.servingGrams ?? 100)),
            servingUnit: food.servingDesc ?? "serving",
            calories: nut.calories,
            proteinG: nut.protein,
            carbsG: nut.carbs,
            fatG: nut.fat,
            fiberG: nut.fiber,
            sugarG: nut.sugar,
            sodiumMg: nut.sodium,
            saturatedFatG: nut.saturatedFat,
            transFatG: nut.transFat,
            cholesterolMg: nut.cholesterol,
            addedSugarG: nut.addedSugar,
            vitaminDMcg: nut.vitaminD,
            calciumMg: nut.calcium,
            ironMg: nut.iron,
            potassiumMg: nut.potassium,
            vitaminAMcgRAE: nut.vitaminA,
            vitaminCMg: nut.vitaminC,
            vitaminB12Mcg: nut.vitaminB12,
            folateMcgDFE: nut.folate,
            magnesiumMg: nut.magnesium,
            zincMg: nut.zinc,
            caloriesPer100g: per100.calories,
            proteinPer100g: per100.protein,
            carbsPer100g: per100.carbs,
            fatPer100g: per100.fat,
            fiberPer100g: per100.fiber,
            sugarPer100g: per100.sugar,
            sodiumPer100g: per100.sodium,
            saturatedFatPer100g: per100.saturatedFat,
            transFatPer100g: per100.transFat,
            cholesterolPer100g: per100.cholesterol,
            addedSugarPer100g: per100.addedSugar,
            vitaminDPer100g: per100.vitaminD,
            calciumPer100g: per100.calcium,
            ironPer100g: per100.iron,
            potassiumPer100g: per100.potassium,
            vitaminAPer100g: per100.vitaminA,
            vitaminCPer100g: per100.vitaminC,
            vitaminB12Per100g: per100.vitaminB12,
            folatePer100g: per100.folate,
            magnesiumPer100g: per100.magnesium,
            zincPer100g: per100.zinc,
            rawUserInput: "Manual entry",
            fdcId: food.fdcId,
            foodDatabaseId: food.id,
            source: food.source,
            barcode: food.barcode
        )
        modelContext.insert(entry)
        onLog?()
        dismiss()
    }
}
