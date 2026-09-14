import SwiftUI
import SwiftData
import UIKit

struct FoodEntryEditView: View {
    let entry: FoodEntry
    private let originalPortion: FoodPortionSnapshot
    @State private var portionGrams: Double
    @State private var servings: Double
    @State private var mealSelection: String
    @State private var showDeleteConfirm = false
    @State private var didCopyFoodName = false
    @State private var saveError: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var evidenceRecords: [ResolvedFoodEvidence]

    init(entry: FoodEntry) {
        self.entry = entry
        originalPortion = FoodPortionSnapshot(entry)
        _portionGrams   = State(initialValue: entry.portionGrams)
        _servings       = State(initialValue: entry.servings)
        _mealSelection  = State(initialValue: entry.meal)
    }

    private var amountBinding: Binding<Double> {
        Binding(get: { servings }, set: { value in
            servings = value
            if originalPortion.hasKnownWeight { portionGrams = value * originalPortion.gramsPerServing }
        })
    }

    private var gramsBinding: Binding<Double> {
        Binding(get: { portionGrams }, set: { value in
            portionGrams = value
            servings = value / originalPortion.gramsPerServing
        })
    }

    private var validPortion: Bool {
        servings.isFinite && (0.05...100).contains(servings)
            && (!originalPortion.hasKnownWeight || (portionGrams.isFinite && (1...5000).contains(portionGrams)))
    }

    private var amountNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }

    var scaledNutrition: NutritionValues {
        originalPortion.scaledNutrition(grams: portionGrams, servings: servings)
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
                        TextField("Amount", value: amountBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .accessibilityIdentifier("foodEdit.amount")
                        
                        Text(displayUnit(for: servings, unit: entry.servingUnit))
                            .foregroundStyle(.secondary)
                    }

                    if originalPortion.hasKnownWeight {
                        HStack {
                            Text("Total Grams")
                            Spacer()
                            TextField("grams", value: gramsBinding, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .accessibilityIdentifier("foodEdit.grams")
                        }
                    } else {
                        Text("Nutrition is calculated per portion. A weight in grams isn't available for this food.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !validPortion {
                        Text("Enter a positive amount up to 100 portions.")
                            .font(.footnote)
                            .foregroundStyle(NomvaTheme.danger)
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
                        .disabled(!validPortion)
                        .accessibilityIdentifier("foodEdit.save")
                }
            }
            .alert("Couldn't save this entry", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "Please try again.") }
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
        guard validPortion else { return }
        let scale = originalPortion.hasKnownWeight
            ? portionGrams / originalPortion.grams
            : servings / max(originalPortion.servings, 0.05)
        // A meal-only edit must preserve the original portion description and nutrition.
        let description = abs(scale - 1) < 0.000001
            ? entry.portionDescription
            : FoodPortionMath.resizedDescription(for: entry, scale: scale,
                description: formattedPortionDescription(amount: servings, unit: entry.servingUnit))
        let oldMeal = entry.meal
        let oldDescription = entry.portionDescription
        originalPortion.apply(to: entry, scale: scale, servings: servings,
                              unit: entry.servingUnit, description: description)
        entry.meal = mealSelection
        do {
            try modelContext.save()
            dismiss()
        } catch {
            originalPortion.apply(to: entry, scale: 1, servings: originalPortion.servings,
                                  unit: entry.servingUnit, description: oldDescription)
            entry.meal = oldMeal
            saveError = "Your previous portion was kept. Please try saving again."
        }
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
