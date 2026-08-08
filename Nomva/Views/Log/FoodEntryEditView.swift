import SwiftUI
import SwiftData
import UIKit

struct FoodEntryEditView: View {
    let entry: FoodEntry
    @State private var portionGrams: Double
    @State private var servings: Double
    @State private var mealSelection: String
    @State private var showDeleteConfirm = false
    @State private var didCopyFoodName = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var evidenceRecords: [ResolvedFoodEvidence]

    init(entry: FoodEntry) {
        self.entry = entry
        _portionGrams   = State(initialValue: entry.portionGrams)
        _servings       = State(initialValue: entry.servings)
        _mealSelection  = State(initialValue: entry.meal)
    }

    private var baseGramsPerServing: Double {
        (portionGrams / max(servings, 0.01))
    }

    private var amountNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }

    var scaledNutrition: NutritionValues {
        let factor = portionGrams / 100
        return NutritionValues(
            calories: entry.caloriesPer100g * factor,
            protein:  entry.proteinPer100g  * factor,
            carbs:    entry.carbsPer100g    * factor,
            fat:      entry.fatPer100g      * factor,
            fiber:    entry.fiberPer100g    * factor,
            sugar:    entry.sugarPer100g    * factor,
            sodium:   entry.sodiumPer100g   * factor,
            saturatedFat: entry.saturatedFatPer100g.map { $0 * factor },
            transFat: entry.transFatPer100g.map { $0 * factor },
            cholesterol: entry.cholesterolPer100g.map { $0 * factor },
            addedSugar: entry.addedSugarPer100g.map { $0 * factor },
            vitaminD: entry.vitaminDPer100g.map { $0 * factor },
            calcium: entry.calciumPer100g.map { $0 * factor },
            iron: entry.ironPer100g.map { $0 * factor },
            potassium: entry.potassiumPer100g.map { $0 * factor },
            vitaminA: entry.vitaminAPer100g.map { $0 * factor },
            vitaminC: entry.vitaminCPer100g.map { $0 * factor },
            vitaminB12: entry.vitaminB12Per100g.map { $0 * factor },
            folate: entry.folatePer100g.map { $0 * factor },
            magnesium: entry.magnesiumPer100g.map { $0 * factor },
            zinc: entry.zincPer100g.map { $0 * factor }
        )
    }

    private var nutritionEvidence: ResolvedFoodEvidence? {
        evidenceRecords
            .filter { $0.foodEntryId == entry.id }
            .max { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.headline)
                                .textSelection(.enabled)
                            if let brand = entry.brand {
                                Text(brand)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }

                        Spacer(minLength: 8)

                        Button(action: copyFoodName) {
                            Image(systemName: didCopyFoodName ? "checkmark" : "doc.on.doc")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(didCopyFoodName ? NomvaTheme.success : NomvaTheme.accent)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(didCopyFoodName ? "Food name copied" : "Copy food name")
                    }
                }

                if let nutritionEvidence {
                    Section("Nutrition Source") {
                        LabeledContent("Type", value: sourceLabel(for: nutritionEvidence))

                        if let sourceURL = nutritionEvidence.sourceURL,
                           let url = URL(string: sourceURL) {
                            Link(destination: url) {
                                Label(
                                    nutritionEvidence.sourceTitle ?? "View source",
                                    systemImage: "arrow.up.right.square"
                                )
                            }
                        }

                        if let evidence = nutritionEvidence.evidence,
                           !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(evidence)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if nutritionEvidence.sourceType == "web_estimate" {
                            Text("This nutrition is an estimate based on the cited menu information. Review the source when precision matters.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Portion") {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("Amount", value: $servings, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChange(of: servings) { _, newValue in
                                portionGrams = newValue * (entry.portionGrams / max(entry.servings, 0.1))
                            }
                        
                        Text(displayUnit(for: servings, unit: entry.servingUnit))
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
                            .foregroundColor(entry.isFavorite ? NomvaTheme.danger : .secondary)
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

    private func copyFoodName() {
        UIPasteboard.general.string = entry.name
        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyFoodName = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyFoodName = false
            }
        }
    }

    private func sourceLabel(for evidence: ResolvedFoodEvidence) -> String {
        switch evidence.sourceType {
        case "web_published":
            return "Published menu nutrition"
        case "web_estimate":
            return "Menu-based estimate"
        case "custom":
            return "Custom food"
        case "recent":
            return "Previously logged food"
        default:
            return evidence.fdcId == nil ? "Food database" : "USDA FoodData Central"
        }
    }

    private func saveChanges() {
        // Clamp typed portions to the same sane bounds the AI pipeline uses
        // (servings 0.05–100, grams 1–5,000) so a stray keystroke can't
        // create a 3-million-calorie day.
        servings = servings.isFinite ? min(max(servings, 0.05), 100) : 1
        portionGrams = portionGrams.isFinite ? min(max(portionGrams, 1), 5000) : entry.portionGrams

        let nutrition = scaledNutrition
        entry.portionGrams = portionGrams
        entry.servings = servings
        entry.portionDescription = formattedPortionDescription(amount: servings, unit: entry.servingUnit)
        entry.meal = mealSelection
        entry.calories = nutrition.calories
        entry.proteinG = nutrition.protein
        entry.carbsG = nutrition.carbs
        entry.fatG = nutrition.fat
        entry.fiberG = nutrition.fiber
        entry.sugarG = nutrition.sugar
        entry.sodiumMg = nutrition.sodium
        entry.saturatedFatG = nutrition.saturatedFat
        entry.transFatG = nutrition.transFat
        entry.cholesterolMg = nutrition.cholesterol
        entry.addedSugarG = nutrition.addedSugar
        entry.vitaminDMcg = nutrition.vitaminD
        entry.calciumMg = nutrition.calcium
        entry.ironMg = nutrition.iron
        entry.potassiumMg = nutrition.potassium
        entry.vitaminAMcgRAE = nutrition.vitaminA
        entry.vitaminCMg = nutrition.vitaminC
        entry.vitaminB12Mcg = nutrition.vitaminB12
        entry.folateMcgDFE = nutrition.folate
        entry.magnesiumMg = nutrition.magnesium
        entry.zincMg = nutrition.zinc
        dismiss()
    }

    private func formattedPortionDescription(amount: Double, unit: String) -> String {
        let amountText = amountNumberFormatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(amountText) \(displayUnit(for: amount, unit: unit))"
    }

    private func displayUnit(for amount: Double, unit: String) -> String {
        let singular = canonicalUnit(from: unit)
        if abs(amount - 1) < 0.0001 {
            return singular
        }
        return pluralizedUnit(from: singular)
    }

    private func canonicalUnit(from unit: String) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "serving" }

        if trimmed.hasSuffix("ies"), trimmed.count > 3 {
            return String(trimmed.dropLast(3)) + "y"
        }

        if trimmed.hasSuffix("s"), trimmed.count > 1, !trimmed.hasSuffix("ss") {
            return String(trimmed.dropLast())
        }

        return trimmed
    }

    private func pluralizedUnit(from singularUnit: String) -> String {
        guard !singularUnit.isEmpty else { return "servings" }

        if singularUnit.hasSuffix("y"),
           singularUnit.count > 1,
           !"aeiou".contains(lastCharacterBeforeFinalCharacter(in: singularUnit)) {
            return String(singularUnit.dropLast()) + "ies"
        }

        if singularUnit.hasSuffix("s")
            || singularUnit.hasSuffix("x")
            || singularUnit.hasSuffix("z")
            || singularUnit.hasSuffix("ch")
            || singularUnit.hasSuffix("sh") {
            return singularUnit + "es"
        }

        return singularUnit + "s"
    }

    private func lastCharacterBeforeFinalCharacter(in text: String) -> Character {
        text[text.index(before: text.index(before: text.endIndex))]
    }
}
