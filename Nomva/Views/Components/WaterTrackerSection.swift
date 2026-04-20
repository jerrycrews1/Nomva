import SwiftUI
import SwiftData

struct WaterTrackerSection: View {
    @Query private var allWaterEntries: [WaterEntry]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("water_goal_oz") private var goalOz: Double = 64

    private let quickAmounts: [Double] = [8, 12, 16, 20]

    private var totalOz: Double {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: todayStart)!
        
        return allWaterEntries
            .filter { $0.date >= todayStart && $0.date < tomorrow }
            .reduce(0) { $0 + $1.amountOz }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hydration")
                        .font(.subheadline.weight(.semibold))

                    Text("\(Int(totalOz)) / \(Int(goalOz)) oz")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }

                Spacer()

                Image(systemName: "drop.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
                    .padding(7)
                    .background(Color.blue.opacity(0.10))
                    .clipShape(Circle())
            }

            ProgressView(value: min(totalOz / goalOz, 1.0))
                .tint(.blue)
                .scaleEffect(x: 1, y: 0.65)

            HStack(spacing: 6) {
                ForEach(quickAmounts, id: \.self) { oz in
                    Button {
                        let entry = WaterEntry(amountOz: oz)
                        modelContext.insert(entry)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Text("+\(Int(oz))")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
                            .padding(.vertical, NomvaTheme.chipVerticalPadding)
                            .background(Color.blue.opacity(0.10))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
        .animation(.spring(), value: totalOz)
    }
}
