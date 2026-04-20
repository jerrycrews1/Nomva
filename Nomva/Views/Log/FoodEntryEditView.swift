import SwiftUI
import SwiftData

struct FoodEntryEditView: View {
    let entry: FoodEntry
    @State private var portionGrams: Double
    @State private var servings: Double
    @State private var mealSelection: String
    @State private var showDeleteConfirm = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(entry: FoodEntry) {
        self.entry = entry
        _portionGrams   = State(initialValue: entry.portionGrams)
        _servings       = State(initialValue: entry.servings)
        _mealSelection  = State(initialValue: entry.meal)
    }

    private var baseGramsPerServing: Double {
        (portionGrams / max(servings, 0.01))
    }

    var scaledNutrition: NutritionValues {
        let factor = portionGrams / 100
        return NutritionValues(
            calories: entry.caloriesPer100g * factor,
            protein:  entry.proteinPer100g  * factor,
            carbs:    entry.carbsPer100g    * factor,
            fat:      entry.fatPer100g      * factor,
            fiber:    entry.fiberPer100g    * factor,
            sugar:    entry.sugarG, // simplified
            sodium:   entry.sodiumMg
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline)
                        if let brand = entry.brand {
                            Text(brand).foregroundColor(.secondary).font(.subheadline)
                        }
                    }
                }

                Section("Portion") {
                    HStack {
                        Text("Servings")
                        Spacer()
                        TextField("Amount", value: $servings, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChange(of: servings) { _, newValue in
                                portionGrams = newValue * (entry.portionGrams / max(entry.servings, 0.1))
                            }
                        
                        Text(entry.servingUnit)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Total Grams")
                        Spacer()
                        TextField("grams", value: $portionGrams, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChange(of: portionGrams) { _, newValue in
                                servings = newValue / max(entry.portionGrams / max(entry.servings, 0.1), 0.1)
                            }
                    }
                }

                Section("Meal") {
                    Picker("Meal", selection: $mealSelection) {
                        Text("Breakfast").tag("breakfast")
                        Text("Lunch").tag("lunch")
                        Text("Dinner").tag("dinner")
                        Text("Snack").tag("snack")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Nutrition Preview") {
                    NutritionRow(label: "Calories", value: scaledNutrition.calories, unit: "kcal")
                    NutritionRow(label: "Protein",  value: scaledNutrition.protein,  unit: "g")
                    NutritionRow(label: "Carbs",    value: scaledNutrition.carbs,    unit: "g")
                    NutritionRow(label: "Fat",      value: scaledNutrition.fat,      unit: "g")
                    NutritionRow(label: "Fiber",    value: scaledNutrition.fiber,    unit: "g")
                }

                Section {
                    HStack {
                        Button {
                            entry.isFavorite.toggle()
                        } label: {
                            Label(
                                entry.isFavorite ? "Remove Favorite" : "Add to Favorites",
                                systemImage: entry.isFavorite ? "heart.fill" : "heart"
                            )
                            .foregroundColor(entry.isFavorite ? .red : .secondary)
                        }
                    }

                    Button("Delete Entry", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChanges() }
                        .bold()
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    modelContext.delete(entry)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private func saveChanges() {
        let nutrition = scaledNutrition
        entry.portionGrams = portionGrams
        entry.servings = servings
        entry.portionDescription = "\(String(format: "%.1g", servings)) \(entry.servingUnit)"
        entry.meal = mealSelection
        entry.calories = nutrition.calories
        entry.proteinG = nutrition.protein
        entry.carbsG = nutrition.carbs
        entry.fatG = nutrition.fat
        entry.fiberG = nutrition.fiber
        dismiss()
    }
}
