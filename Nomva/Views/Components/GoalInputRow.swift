import SwiftUI

struct GoalInputRow: View {
    let label: String
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    TextField("", value: $value, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text(unit)
                        .foregroundColor(.secondary)
                }
            }

            Slider(value: $value, in: range)
                .tint(NomvaTheme.accent)
        }
        .padding(.vertical, 4)
    }
}
