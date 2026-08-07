import SwiftUI
import SwiftData

/// Shows the photo the user took/selected, the foods the LLM identified,
/// and lets the user tap each item to adjust servings/meal before logging.
struct PhotoFoodReviewView: View {
    let image: UIImage
    let foods: [RemoteAPIProvider.PhotoFoodItem]
    let meal: String
    let onDone: ([RemoteAPIProvider.PhotoFoodItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loggedIndices: Set<Int> = []
    @State private var selectedFoodIndex: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    photoHeader
                    foodsList
                    progressFooter
                }
                .padding(.vertical)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Photo Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(item: selectedBinding) { selection in
                ManualFoodDetailView(
                    food: foods[selection.index].asFoodItem,
                    meal: meal
                ) {
                    loggedIndices.insert(selection.index)
                    if loggedIndices.count == foods.count {
                        let all = foods
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onDone(all)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var photoHeader: some View {
        VStack(spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

            Text("Tap each item to adjust servings and meal time")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var foodsList: some View {
        VStack(spacing: 0) {
            ForEach(0..<foods.count, id: \.self) { index in
                PhotoFoodRow(
                    food: foods[index],
                    isLogged: loggedIndices.contains(index),
                    isLast: index == foods.count - 1
                ) {
                    selectedFoodIndex = index
                }
            }
        }
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
    }

    private var progressFooter: some View {
        HStack {
            Text("\(loggedIndices.count) of \(foods.count) logged")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if loggedIndices.count == foods.count {
                Text("All done!")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomvaTheme.success)
            }
        }
        .padding(.horizontal, 24)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                let logged = foods.enumerated()
                    .filter { loggedIndices.contains($0.offset) }
                    .map(\.element)
                onDone(logged)
                dismiss()
            }
            .fontWeight(.semibold)
            .foregroundStyle(NomvaTheme.accent)
            .disabled(loggedIndices.isEmpty)
        }
    }

    private var selectedBinding: Binding<SelectedPhotoFood?> {
        Binding(
            get: { selectedFoodIndex.map { SelectedPhotoFood(index: $0) } },
            set: { selectedFoodIndex = $0?.index }
        )
    }
}

struct NutritionLabelReviewView: View {
    let image: UIImage
    let scannedFood: RemoteAPIProvider.NutritionLabelFood
    let initialMeal: MealCategory
    let logDate: Date
    let onDone: (_ foodName: String, _ calories: Double, _ wasLogged: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String
    @State private var brand: String
    @State private var servingDescription: String
    @State private var servingGrams: Double?
    @State private var calories: Double
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var fiber: Double?
    @State private var servings = 1.0
    @State private var meal: MealCategory
    @State private var saveError: String?

    init(
        image: UIImage,
        scannedFood: RemoteAPIProvider.NutritionLabelFood,
        initialMeal: MealCategory,
        logDate: Date,
        onDone: @escaping (_ foodName: String, _ calories: Double, _ wasLogged: Bool) -> Void
    ) {
        self.image = image
        self.scannedFood = scannedFood
        self.initialMeal = initialMeal
        self.logDate = logDate
        self.onDone = onDone
        _name = State(initialValue: scannedFood.name)
        _brand = State(initialValue: scannedFood.brand)
        _servingDescription = State(initialValue: scannedFood.servingDescription)
        _servingGrams = State(initialValue: scannedFood.servingGrams)
        _calories = State(initialValue: scannedFood.calories)
        _protein = State(initialValue: scannedFood.protein)
        _carbs = State(initialValue: scannedFood.carbs)
        _fat = State(initialValue: scannedFood.fat)
        _fiber = State(initialValue: scannedFood.fiber)
        _meal = State(initialValue: initialMeal)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .listRowInsets(EdgeInsets())
                }

                Section("Food") {
                    TextField("Name (required)", text: $name)
                    TextField("Brand (optional)", text: $brand)
                }

                Section("Per Serving") {
                    if [servingGrams, protein, carbs, fat, fiber].contains(where: { $0 == nil }) {
                        Label(
                            "Review each blank value; it was not readable on the label.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    TextField("Serving size", text: $servingDescription)
                    OptionalNutritionInputRow(label: "Weight", value: $servingGrams, unit: "g")
                    NutritionInputRow(label: "Calories", value: $calories, unit: "kcal")
                    OptionalNutritionInputRow(label: "Protein", value: $protein, unit: "g")
                    OptionalNutritionInputRow(label: "Carbs", value: $carbs, unit: "g")
                    OptionalNutritionInputRow(label: "Fat", value: $fat, unit: "g")
                    OptionalNutritionInputRow(label: "Fiber", value: $fiber, unit: "g")
                }

                Section("Log Now") {
                    NutritionInputRow(label: "Servings", value: $servings, unit: "")
                    Picker("Meal", selection: $meal) {
                        ForEach(MealCategory.allCases) { meal in
                            Text(meal.title).tag(meal)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Review Nutrition Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        save(logNow: true)
                    } label: {
                        Label("Save & Log", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NomvaPrimaryButtonStyle())
                    .disabled(!canSave)

                    Button("Save Food Only") {
                        save(logNow: false)
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(!canSave)
                }
                .padding(.horizontal, NomvaTheme.contentInset)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .alert("Could Not Save Food", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let servingGrams,
              let protein,
              let carbs,
              let fat,
              let fiber else { return false }
        return servingGrams.isFinite && servingGrams > 0
            && servings.isFinite && servings > 0 && servings <= 100
            && [calories, protein, carbs, fat, fiber].allSatisfy { $0.isFinite && $0 >= 0 }
    }

    private func save(logNow: Bool) {
        guard canSave,
              let servingGrams,
              let protein,
              let carbs,
              let fat,
              let fiber else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanServing = servingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let servingLabel = cleanServing.isEmpty ? "1 serving" : cleanServing

        let customFood = CustomFood(
            name: cleanName,
            brand: cleanBrand.isEmpty ? nil : cleanBrand,
            servingDesc: servingLabel,
            servingGrams: servingGrams,
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fiberG: fiber
        )
        modelContext.insert(customFood)

        let loggedCalories = calories * servings
        var loggedEntry: FoodEntry?
        if logNow {
            let grams = servingGrams * servings
            let per100Factor = 100 / servingGrams
            let portion = servings == 1
                ? servingLabel
                : "\(servings.formatted()) servings (\(servingLabel) each)"
            let entry = FoodEntry(
                name: cleanName,
                brand: cleanBrand.isEmpty ? nil : cleanBrand,
                meal: meal.rawValue,
                date: logDate,
                portionGrams: grams,
                portionDescription: portion,
                servings: servings,
                servingUnit: "serving",
                calories: loggedCalories,
                proteinG: protein * servings,
                carbsG: carbs * servings,
                fatG: fat * servings,
                fiberG: fiber * servings,
                caloriesPer100g: calories * per100Factor,
                proteinPer100g: protein * per100Factor,
                carbsPer100g: carbs * per100Factor,
                fatPer100g: fat * per100Factor,
                fiberPer100g: fiber * per100Factor,
                rawUserInput: "Nutrition facts photo",
                source: "nutrition_label"
            )
            loggedEntry = entry
            modelContext.insert(entry)
        }

        do {
            try modelContext.save()
            onDone(cleanName, loggedCalories, logNow)
            dismiss()
        } catch {
            modelContext.delete(customFood)
            if let loggedEntry {
                modelContext.delete(loggedEntry)
            }
            saveError = "Nomva could not save this item. Please review the values and try again."
        }
    }
}

private struct OptionalNutritionInputRow: View {
    let label: String
    @Binding var value: Double?
    let unit: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("Required", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }
}

// MARK: - Row View (extracted to help the type checker)

private struct PhotoFoodRow: View {
    let food: RemoteAPIProvider.PhotoFoodItem
    let isLogged: Bool
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if !isLogged { onTap() }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(isLogged)

            if !isLast {
                Divider().padding(.leading, 52)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Image(systemName: isLogged ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(isLogged ? NomvaTheme.success : NomvaTheme.accent)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(food.name.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isLogged ? .secondary : .primary)
                Text(food.portion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let calText: String = "\(food.calories.safeRoundedInt) cal"
            let macroText: String = "\(food.protein.safeRoundedInt)P · \(food.carbs.safeRoundedInt)C · \(food.fat.safeRoundedInt)F"

            VStack(alignment: .trailing, spacing: 2) {
                Text(calText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isLogged ? Color.secondary : NomvaTheme.accent)
                Text(macroText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !isLogged {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isLogged ? 0.6 : 1)
    }
}

// Identifiable wrapper so .sheet(item:) works
private struct SelectedPhotoFood: Identifiable {
    let index: Int
    var id: Int { index }
}

// Convert a PhotoFoodItem into a FoodItem for ManualFoodDetailView
extension RemoteAPIProvider.PhotoFoodItem {
    var asFoodItem: FoodItem {
        let g = max(grams, 1)
        return FoodItem(
            id: Int.random(in: 100_000...999_999),
            name: name.capitalized,
            servingGrams: g,
            servingDesc: portion,
            caloriesPerServing: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fiberG: fiber ?? 0,
            sugarG: 0,
            sodiumMg: 0
        )
    }
}
