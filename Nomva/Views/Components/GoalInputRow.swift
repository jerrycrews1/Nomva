import SwiftUI

struct GoalInputRow: View {
    let label: String
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = NomvaTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                HStack(spacing: 4) {
                    TextField(
                        label,
                        value: $value,
                        format: .number.precision(.fractionLength(0))
                    )
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 72)

                    Text(unit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(UIColor.separator).opacity(0.35), lineWidth: 1)
                }
            }

            Slider(value: $value, in: range, step: step)
                .tint(tint)
                .accessibilityLabel(label)
                .accessibilityValue("\(value.safeRoundedInt) \(unit)")
        }
        .padding(.vertical, 2)
    }
}
