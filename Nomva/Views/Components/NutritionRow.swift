import SwiftUI

struct NutritionRow: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value, specifier: "%.1f") \(unit)")
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

#Preview {
    Form {
        NutritionRow(label: "Calories", value: 420.5, unit: "kcal")
        NutritionRow(label: "Protein",  value: 32.1,  unit: "g")
    }
}
