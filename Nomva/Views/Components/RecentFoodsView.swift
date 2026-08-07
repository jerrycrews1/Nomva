import SwiftUI
import SwiftData

private struct RecentFoodAggregate {
    let id: String
    let entry: FoodEntry
    let recentCount: Int
    let sameWeekdayCount: Int
    let mealCounts: [String: Int]
    let isFavorite: Bool
    let score: Double
}

private struct RecentFoodSuggestionCache: Codable {
    let fingerprint: String
    let candidateIds: [String]
    let aiRanked: Bool
    let createdAt: Date
}

struct RecentFoodsView: View {
    @Query(
        sort: \FoodEntry.date,
        order: .reverse
    ) private var allEntries: [FoodEntry]

    @AppStorage("recent_food_suggestion_cache_v1") private var cacheData = Data()
    @State private var rankedCandidateIDs: [String] = []
    @State private var isAIRanked = false

    let targetDate: Date
    var onQuickAdd: (FoodEntry) -> Void

    init(targetDate: Date = .now, onQuickAdd: @escaping (FoodEntry) -> Void) {
        self.targetDate = targetDate
        self.onQuickAdd = onQuickAdd
    }

    private var calendar: Calendar { Calendar.current }
    private var likelyMeal: MealCategory {
        switch calendar.component(.hour, from: targetDate) {
        case 5..<11: .breakfast
        case 11..<16: .lunch
        case 16..<22: .dinner
        default: .snack
        }
    }

    private var aggregates: [RecentFoodAggregate] {
        let dayStart = calendar.startOfDay(for: targetDate)
        let historyStart = calendar.date(byAdding: .day, value: -90, to: dayStart) ?? .distantPast
        let targetWeekday = calendar.component(.weekday, from: targetDate)
        let history = allEntries.filter { $0.date < dayStart && $0.date >= historyStart }

        struct Builder {
            let entry: FoodEntry
            var count: Int
            var sameWeekdayCount: Int
            var mealCounts: [String: Int]
            var isFavorite: Bool
        }

        var grouped: [String: Builder] = [:]
        for entry in history.prefix(400) {
            let key = normalizedIdentity(for: entry)
            guard !key.isEmpty else { continue }
            if var existing = grouped[key] {
                existing.count += 1
                existing.sameWeekdayCount += calendar.component(.weekday, from: entry.date) == targetWeekday ? 1 : 0
                existing.mealCounts[MealCategory(storedValue: entry.meal).rawValue, default: 0] += 1
                existing.isFavorite = existing.isFavorite || entry.isFavorite
                grouped[key] = existing
            } else {
                grouped[key] = Builder(
                    entry: entry,
                    count: 1,
                    sameWeekdayCount: calendar.component(.weekday, from: entry.date) == targetWeekday ? 1 : 0,
                    mealCounts: [MealCategory(storedValue: entry.meal).rawValue: 1],
                    isFavorite: entry.isFavorite
                )
            }
        }

        return grouped.values.map { builder in
            let ageDays = max(calendar.dateComponents([.day], from: builder.entry.date, to: targetDate).day ?? 0, 0)
            let recency = max(30 - Double(ageDays), 0) * 2.5
            let sameMeal = Double(builder.mealCounts[likelyMeal.rawValue, default: 0]) * 38
            let frequency = Double(builder.count) * 14
            let weekday = Double(builder.sameWeekdayCount) * 18
            let favorite = builder.isFavorite ? 32.0 : 0
            return RecentFoodAggregate(
                id: builder.entry.id.uuidString,
                entry: builder.entry,
                recentCount: builder.count,
                sameWeekdayCount: builder.sameWeekdayCount,
                mealCounts: builder.mealCounts,
                isFavorite: builder.isFavorite,
                score: recency + sameMeal + frequency + weekday + favorite
            )
        }
        .sorted {
            if $0.score == $1.score {
                return $0.entry.date > $1.entry.date
            }
            return $0.score > $1.score
        }
        .prefix(24)
        .map { $0 }
    }

    private var displayedEntries: [FoodEntry] {
        let byID = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.id, $0.entry) })
        var seen = Set<String>()
        return (rankedCandidateIDs + aggregates.map(\.id))
            .compactMap { id -> FoodEntry? in
                guard seen.insert(id).inserted else { return nil }
                return byID[id]
            }
            .prefix(8)
            .map { $0 }
    }

    private var fingerprint: String {
        let day = calendar.startOfDay(for: targetDate).timeIntervalSince1970
        let snapshot = aggregates.map { aggregate in
            let meals = MealCategory.allCases
                .map { "\($0.rawValue):\(aggregate.mealCounts[$0.rawValue, default: 0])" }
                .joined(separator: ",")
            return "\(aggregate.id)|\(aggregate.entry.date.timeIntervalSince1970)|\(aggregate.recentCount)|\(aggregate.sameWeekdayCount)|\(aggregate.isFavorite)|\(meals)"
        }
        .joined(separator: ";")
        return "\(day)|\(likelyMeal.rawValue)|\(snapshot)"
    }

    var body: some View {
        if !displayedEntries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Suggested for \(likelyMeal.title)")
                        .font(.subheadline.weight(.semibold))
                    if isAIRanked {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NomvaTheme.accent)
                            .accessibilityLabel("AI ranked")
                    }
                    Spacer()
                    Text("From your recent foods")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(displayedEntries) { entry in
                            RecentFoodChip(entry: entry, onTap: onQuickAdd)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
            .task(id: fingerprint) {
                await rankSuggestions()
            }
        }
    }

    @MainActor
    private func rankSuggestions() async {
        let localIDs = aggregates.map(\.id)
        rankedCandidateIDs = localIDs
        isAIRanked = false
        guard !localIDs.isEmpty else { return }

        if let cache = try? JSONDecoder().decode(RecentFoodSuggestionCache.self, from: cacheData),
           cache.fingerprint == fingerprint,
           Date.now.timeIntervalSince(cache.createdAt) < 86_400 {
            let allowed = Set(localIDs)
            rankedCandidateIDs = cache.candidateIds.filter(allowed.contains)
            isAIRanked = cache.aiRanked
            return
        }

        guard SubscriptionManager.shared.isPremium else { return }
        let candidates = aggregates.map { aggregate in
            RemoteAPIProvider.RecentFoodSuggestionCandidate(
                id: aggregate.id,
                name: aggregate.entry.name,
                brand: aggregate.entry.brand,
                recentCount: aggregate.recentCount,
                sameWeekdayCount: aggregate.sameWeekdayCount,
                isFavorite: aggregate.isFavorite,
                lastLoggedAt: aggregate.entry.date,
                mealCounts: aggregate.mealCounts
            )
        }

        do {
            let result = try await RemoteAPIProvider(baseURL: NomvaAPI.baseURL).suggestRecentFoods(
                candidates: candidates,
                date: targetDate,
                likelyMeal: likelyMeal
            )
            guard !Task.isCancelled else { return }
            let allowed = Set(localIDs)
            let safeIDs = result.candidateIds.filter(allowed.contains)
            rankedCandidateIDs = safeIDs.isEmpty ? localIDs : safeIDs
            isAIRanked = result.aiRanked && !safeIDs.isEmpty
            if let encoded = try? JSONEncoder().encode(RecentFoodSuggestionCache(
                fingerprint: fingerprint,
                candidateIds: rankedCandidateIDs,
                aiRanked: isAIRanked,
                createdAt: .now
            )) {
                cacheData = encoded
            }
        } catch {
            rankedCandidateIDs = localIDs
            isAIRanked = false
        }
    }

    private func normalizedIdentity(for entry: FoodEntry) -> String {
        "\(entry.brand ?? "")|\(entry.name)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "|")
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

                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
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
        .buttonStyle(.plain)
        .accessibilityLabel("Quick add \(entry.name), \(entry.calories.safeRoundedInt) calories")
    }
}
