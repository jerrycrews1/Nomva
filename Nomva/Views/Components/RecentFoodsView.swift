import SwiftUI
import SwiftData

struct RecentFoodsView: View {
    @Query(
        sort: \FoodEntry.date,
        order: .reverse
    ) private var allEntries: [FoodEntry]

    var onQuickAdd: (FoodEntry) -> Void

    private var recentDistinct: [FoodEntry] {
        // Only look at the last 50 entries to keep it fast
        let subset = allEntries.prefix(50)
        var seen = Set<String>()
        var result: [FoodEntry] = []
        for entry in subset {
            if !seen.contains(entry.name) {
                seen.insert(entry.name)
                result.append(entry)
                if result.count >= 10 { break }
            }
        }
        return result
    }

    var body: some View {
        if !recentDistinct.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Quick add from recent meals")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Tap to reuse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recentDistinct) { entry in
                            RecentFoodChip(entry: entry, onTap: onQuickAdd)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct RecentFoodChip: View {
    let entry: FoodEntry
    var onTap: (FoodEntry) -> Void

    var body: some View {
        Button {
            onTap(entry)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "fork.knife")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomvaTheme.accent)
                        .padding(8)
                        .background(NomvaTheme.accent.opacity(0.10))
                        .clipShape(Circle())
                    Spacer()
                    Text("\(Int(entry.calories)) cal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.portionDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            .nomvaCard(.subtle, padding: 14)
        }
        .accessibilityLabel("Quick add \(entry.name), \(Int(entry.calories)) calories")
    }
}
