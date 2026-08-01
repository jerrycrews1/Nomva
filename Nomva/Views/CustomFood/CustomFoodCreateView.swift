import SwiftUI
import SwiftData

struct CustomFoodCreateView: View {
    @State private var name: String = ""
    @State private var brand: String = ""
    @State private var servingDesc: String = ""
    @State private var servingGrams: Double = 100
    @State private var calories: Double = 0
    @State private var proteinG: Double = 0
    @State private var carbsG: Double = 0
    @State private var fatG: Double = 0
    @State private var fiberG: Double = 0
    @State private var barcode: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(initialBarcode: String = "", initialName: String = "") {
        _barcode = State(initialValue: initialBarcode)
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            Section("Food Info") {
                TextField("Name (required)", text: $name)
                    .accessibilityLabel("Food name")
                TextField("Brand or Restaurant (optional)", text: $brand)
                    .accessibilityLabel("Brand name")
                TextField("Barcode (optional)", text: $barcode)
                    .keyboardType(.numberPad)
                    .textContentType(.none)
                    .accessibilityLabel("Barcode")
            }

            Section("Serving Size") {
                TextField("Description (e.g. '1 cup', '1 bar')", text: $servingDesc)

                HStack {
                    Text("Weight (grams)")
                    Spacer()
                    TextField("grams", value: $servingGrams, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }

            Section("Nutrition Per Serving") {
                NutritionInputRow(label: "Calories",  value: $calories, unit: "kcal")
                NutritionInputRow(label: "Protein",   value: $proteinG, unit: "g")
                NutritionInputRow(label: "Carbs",     value: $carbsG,   unit: "g")
                NutritionInputRow(label: "Fat",       value: $fatG,     unit: "g")
                NutritionInputRow(label: "Fiber",     value: $fiberG,   unit: "g")
            }
        }
        .navigationTitle("Add Custom Food")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveCustomFood() }
                    .bold()
                    .disabled(name.isEmpty || calories == 0)
            }
        }
    }

    private func saveCustomFood() {
        let trimmedBarcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let food = CustomFood(
            name: name.trimmingCharacters(in: .whitespaces),
            brand: brand.isEmpty ? nil : brand,
            servingDesc: servingDesc.isEmpty ? "1 serving" : servingDesc,
            servingGrams: servingGrams,
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            barcode: trimmedBarcode.isEmpty ? nil : trimmedBarcode
        )
        modelContext.insert(food)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Nutrition Input Row

struct NutritionInputRow: View {
    let label: String
    @Binding var value: Double
    let unit: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit)
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }
}
