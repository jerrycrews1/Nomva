import SwiftUI
import SwiftData

struct RecentFoodsView: View {
    @Query(
        sort: \FoodEntry.date,
        order: .reverse
    ) private var allEntries: [FoodEntry]

    var onQuickAdd: (FoodEntry) -> Void

    private var recentDistinct: [FoodEntry] {
        let favorites = allEntries.filter(\.isFavorite)
        let subset = favorites + Array(allEntries.prefix(50))
        var seen = Set<String>()
        var result: [FoodEntry] = []
        for entry in subset {
            let key = "\(entry.brand ?? "")|\(entry.name)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted {
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
                    Text("Favorites & Recent")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Choose a meal next")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
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
                    Image(systemName: entry.isFavorite ? "star.fill" : "fork.knife")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomvaTheme.accent)
                        .padding(8)
                        .background(NomvaTheme.accent.opacity(0.10))
                        .clipShape(Circle())
                    Spacer()
                    Text("\(entry.calories.safeRoundedInt) cal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                // Always reserve two lines for the name and one for the
                // portion so every chip in the row is the same size, whether
                // the name is "Mayo" or "Chicken Breast Burrito Bowl".
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(entry.portionDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 170, alignment: .topLeading)
            .nomvaCard(.subtle, padding: 14)
        }
        .accessibilityLabel("Quick add \(entry.name), \(entry.calories.safeRoundedInt) calories")
    }
}
