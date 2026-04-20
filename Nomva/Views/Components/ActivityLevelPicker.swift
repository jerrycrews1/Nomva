import SwiftUI

struct ActivityLevelPicker: View {
    @Binding var selection: ActivityLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity Level")
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(ActivityLevel.allCases, id: \.self) { level in
                    Button {
                        selection = level
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selection == level ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == level ? NomvaTheme.accent : .secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(level.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(level.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selection == level ? NomvaTheme.accent.opacity(0.10) : Color(UIColor.secondarySystemBackground).opacity(0.72))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var level = ActivityLevel.moderatelyActive
    ActivityLevelPicker(selection: $level)
        .padding()
}
