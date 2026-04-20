import SwiftUI

struct InfoPopoverLabel: View {
    let label: String
    let explanation: String
    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)

            Button {
                showPopover = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("More information about \(label)")
            .popover(isPresented: $showPopover) {
                Text(explanation)
                    .font(.subheadline)
                    .padding()
                    .frame(maxWidth: 280)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

#Preview {
    InfoPopoverLabel(
        label: "TDEE",
        explanation: "Total Daily Energy Expenditure — how many calories you burn in a day including activity."
    )
    .padding()
}
