import SwiftUI

struct NutritionDetailView: View {
    let selectedDate: Date
    let entries: [FoodEntry]
    let allEntries: [FoodEntry]
    let goal: DailyGoal

    @Environment(\.dismiss) private var dismiss

    private var cal: Calendar { Calendar.current }
    private var totals: NutritionTotals { NutritionTotals.from(entries: entries) }
    private var selectedDayStart: Date { cal.startOfDay(for: selectedDate) }
    private var selectedDayEnd: Date { cal.date(byAdding: .day, value: 1, to: selectedDayStart)! }

    private var dateLabel: String {
        if cal.isDateInToday(selectedDate) { return "Today" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = cal.component(.year, from: selectedDate) == cal.component(.year, from: .now)
            ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: selectedDate)
    }

    private var calorieDelta: Double {
        goal.calories - totals.calories
    }

    private var calorieDeltaText: String {
        if calorieDelta >= 0 {
            return "\(calorieDelta.safeRoundedInt) cal left"
        }
        return "\(abs(calorieDelta).safeRoundedInt) cal over"
    }

    private var loggedMealNames: [String] {
        Array(Set(entries.map { $0.meal.capitalized })).sorted()
    }

    private var trendSnapshots: [DailyNutritionSnapshot] {
        (0..<7).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: selectedDayStart) else {
                return nil
            }
            let start = cal.startOfDay(for: date)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let dayEntries = allEntries.filter { $0.date >= start && $0.date < end }
            return DailyNutritionSnapshot(
                date: start,
                totals: NutritionTotals.from(entries: dayEntries),
                entryCount: dayEntries.count
            )
        }
    }

    private var activeTrendSnapshots: [DailyNutritionSnapshot] {
        trendSnapshots.filter { $0.entryCount > 0 }
    }

    private var trendAverage: NutritionTotals {
        guard !activeTrendSnapshots.isEmpty else { return NutritionTotals() }
        let summed = activeTrendSnapshots.reduce(into: NutritionTotals()) { partial, snapshot in
            partial.calories += snapshot.totals.calories
            partial.protein += snapshot.totals.protein
            partial.carbs += snapshot.totals.carbs
            partial.fat += snapshot.totals.fat
            partial.fiber += snapshot.totals.fiber
            partial.sugar += snapshot.totals.sugar
            partial.sodium += snapshot.totals.sodium
            partial.saturatedFat += snapshot.totals.saturatedFat
            partial.transFat += snapshot.totals.transFat
            partial.cholesterol += snapshot.totals.cholesterol
            partial.addedSugar += snapshot.totals.addedSugar
            partial.vitaminD += snapshot.totals.vitaminD
            partial.calcium += snapshot.totals.calcium
            partial.iron += snapshot.totals.iron
            partial.potassium += snapshot.totals.potassium
            partial.vitaminA += snapshot.totals.vitaminA
            partial.vitaminC += snapshot.totals.vitaminC
            partial.vitaminB12 += snapshot.totals.vitaminB12
            partial.folate += snapshot.totals.folate
            partial.magnesium += snapshot.totals.magnesium
            partial.zinc += snapshot.totals.zinc
        }
        let divisor = Double(activeTrendSnapshots.count)
        return NutritionTotals(
            calories: summed.calories / divisor,
            protein: summed.protein / divisor,
            carbs: summed.carbs / divisor,
            fat: summed.fat / divisor,
            fiber: summed.fiber / divisor,
            sugar: summed.sugar / divisor,
            sodium: summed.sodium / divisor,
            saturatedFat: summed.saturatedFat / divisor,
            transFat: summed.transFat / divisor,
            cholesterol: summed.cholesterol / divisor,
            addedSugar: summed.addedSugar / divisor,
            vitaminD: summed.vitaminD / divisor,
            calcium: summed.calcium / divisor,
            iron: summed.iron / divisor,
            potassium: summed.potassium / divisor,
            vitaminA: summed.vitaminA / divisor,
            vitaminC: summed.vitaminC / divisor,
            vitaminB12: summed.vitaminB12 / divisor,
            folate: summed.folate / divisor,
            magnesium: summed.magnesium / divisor,
            zinc: summed.zinc / divisor
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NomvaTheme.sectionGap) {
                    overviewCard
                    macroTargetsCard
                    dailyValueCard
                    vitaminMineralCard
                    trendCard
                    topSourcesCard
                    dataQualityCard
                }
                .padding(.horizontal, NomvaTheme.contentInset)
                .padding(.top, NomvaTheme.topCardGap)
                .padding(.bottom, 28)
            }
            .nomvaScreenBackground()
            .navigationTitle("Nutrition Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            NomvaSectionLabel(
                dateLabel,
                title: "Your nutrition picture",
                detail: entries.isEmpty
                    ? "Log food to see macro progress, label-style nutrients, and trends."
                    : "\(entries.count) item\(entries.count == 1 ? "" : "s") logged\(loggedMealNames.isEmpty ? "" : " across \(loggedMealNames.joined(separator: ", "))")."
            )

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(totals.calories.safeRoundedInt)")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(goal.calories.safeRoundedInt) calories")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                NomvaTag(
                    text: calorieDeltaText,
                    tint: calorieDelta >= 0 ? NomvaTheme.accent : NomvaTheme.danger
                )
            }

            ProgressBar(
                progress: progress(totals.calories, goal.calories),
                tint: calorieDelta >= 0 ? NomvaTheme.accent : NomvaTheme.danger
            )

            HStack(spacing: 10) {
                OverviewPill(title: "Protein", value: "\(totals.protein.safeRoundedInt)g", tint: NomvaTheme.macroProtein)
                OverviewPill(title: "Fiber", value: "\(totals.fiber.safeRoundedInt)g", tint: NomvaTheme.success)
                OverviewPill(title: "Sodium", value: "\(totals.sodium.safeRoundedInt)mg", tint: NomvaTheme.warning)
            }
        }
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    private var macroTargetsCard: some View {
        DetailCard(title: "Macro Targets", subtitle: "Personal goals from Nomva settings.") {
            VStack(spacing: 12) {
                NutrientProgressRow(
                    title: "Calories",
                    amount: totals.calories,
                    unit: "cal",
                    target: goal.calories,
                    targetLabel: "goal",
                    tint: NomvaTheme.accent,
                    direction: .target
                )
                NutrientProgressRow(
                    title: "Protein",
                    amount: totals.protein,
                    unit: "g",
                    target: goal.protein,
                    targetLabel: "goal",
                    tint: NomvaTheme.macroProtein,
                    direction: .target
                )
                NutrientProgressRow(
                    title: "Carbs",
                    amount: totals.carbs,
                    unit: "g",
                    target: goal.carbs,
                    targetLabel: "goal",
                    tint: NomvaTheme.macroCarbs,
                    direction: .target
                )
                NutrientProgressRow(
                    title: "Fat",
                    amount: totals.fat,
                    unit: "g",
                    target: goal.fat,
                    targetLabel: "goal",
                    tint: NomvaTheme.macroFat,
                    direction: .target
                )
                NutrientProgressRow(
                    title: "Fiber",
                    amount: totals.fiber,
                    unit: "g",
                    target: goal.fiber,
                    targetLabel: "goal",
                    tint: .teal,
                    direction: .target
                )
            }
        }
    }

    private var dailyValueCard: some View {
        DetailCard(
            title: "Daily Value Context",
            subtitle: "A label-style read using FDA Daily Values where Nomva has data."
        ) {
            VStack(spacing: 12) {
                NutrientProgressRow(
                    title: "Fiber",
                    amount: totals.fiber,
                    unit: "g",
                    target: 28,
                    targetLabel: "DV",
                    tint: .teal,
                    direction: .target,
                    note: dailyValueCue(amount: totals.fiber, target: 28, direction: .target)
                )
                NutrientProgressRow(
                    title: "Sodium",
                    amount: totals.sodium,
                    unit: "mg",
                    target: 2300,
                    targetLabel: "limit",
                    tint: NomvaTheme.warning,
                    direction: .limit,
                    note: dailyValueCue(amount: totals.sodium, target: 2300, direction: .limit)
                )
                TrackedNutrientProgressRow(
                    title: "Saturated Fat",
                    amount: totals.saturatedFat,
                    unit: "g",
                    target: 20,
                    targetLabel: "limit",
                    tint: NomvaTheme.danger,
                    direction: .limit,
                    knownCount: knownEntryCount(for: \.saturatedFatG),
                    totalCount: entries.count
                )
                TrackedNutrientProgressRow(
                    title: "Added Sugar",
                    amount: totals.addedSugar,
                    unit: "g",
                    target: 50,
                    targetLabel: "limit",
                    tint: .pink,
                    direction: .limit,
                    knownCount: knownEntryCount(for: \.addedSugarG),
                    totalCount: entries.count
                )
                TrackedNutrientProgressRow(
                    title: "Cholesterol",
                    amount: totals.cholesterol,
                    unit: "mg",
                    target: 300,
                    targetLabel: "limit",
                    tint: NomvaTheme.warning,
                    direction: .limit,
                    knownCount: knownEntryCount(for: \.cholesterolMg),
                    totalCount: entries.count
                )
                NutrientProgressRow(
                    title: "Total Carbohydrate",
                    amount: totals.carbs,
                    unit: "g",
                    target: 275,
                    targetLabel: "DV",
                    tint: NomvaTheme.macroCarbs,
                    direction: .target
                )
                NutrientProgressRow(
                    title: "Total Fat",
                    amount: totals.fat,
                    unit: "g",
                    target: 78,
                    targetLabel: "DV",
                    tint: NomvaTheme.macroFat,
                    direction: .limit
                )
                NutrientProgressRow(
                    title: "Total Sugars",
                    amount: totals.sugar,
                    unit: "g",
                    target: nil,
                    targetLabel: nil,
                    tint: .pink,
                    direction: .neutral,
                    note: "Total sugar is tracked separately from added sugar when label data is available."
                )
            }
        }
    }

    private var vitaminMineralCard: some View {
        DetailCard(
            title: "Vitamins & Minerals",
            subtitle: "FDA Daily Values with coverage notes when a food source omits a nutrient."
        ) {
            VStack(spacing: 10) {
                TrackedNutrientProgressRow(title: "Vitamin D", amount: totals.vitaminD, unit: "mcg", target: 20, targetLabel: "DV", tint: NomvaTheme.warning, direction: .target, knownCount: knownEntryCount(for: \.vitaminDMcg), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Calcium", amount: totals.calcium, unit: "mg", target: 1300, targetLabel: "DV", tint: NomvaTheme.info, direction: .target, knownCount: knownEntryCount(for: \.calciumMg), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Iron", amount: totals.iron, unit: "mg", target: 18, targetLabel: "DV", tint: NomvaTheme.danger, direction: .target, knownCount: knownEntryCount(for: \.ironMg), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Potassium", amount: totals.potassium, unit: "mg", target: 4700, targetLabel: "DV", tint: NomvaTheme.success, direction: .target, knownCount: knownEntryCount(for: \.potassiumMg), totalCount: entries.count)

                Divider().opacity(0.5)

                TrackedNutrientProgressRow(title: "Vitamin A", amount: totals.vitaminA, unit: "mcg", target: 900, targetLabel: "DV", tint: NomvaTheme.warning, direction: .target, knownCount: knownEntryCount(for: \.vitaminAMcgRAE), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Vitamin C", amount: totals.vitaminC, unit: "mg", target: 90, targetLabel: "DV", tint: NomvaTheme.success, direction: .target, knownCount: knownEntryCount(for: \.vitaminCMg), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Vitamin B12", amount: totals.vitaminB12, unit: "mcg", target: 2.4, targetLabel: "DV", tint: .purple, direction: .target, knownCount: knownEntryCount(for: \.vitaminB12Mcg), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Folate", amount: totals.folate, unit: "mcg", target: 400, targetLabel: "DV", tint: .teal, direction: .target, knownCount: knownEntryCount(for: \.folateMcgDFE), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Magnesium", amount: totals.magnesium, unit: "mg", target: 420, targetLabel: "DV", tint: .indigo, direction: .target, knownCount: knownEntryCount(for: \.magnesiumMg), totalCount: entries.count)
                TrackedNutrientProgressRow(title: "Zinc", amount: totals.zinc, unit: "mg", target: 11, targetLabel: "DV", tint: .brown, direction: .target, knownCount: knownEntryCount(for: \.zincMg), totalCount: entries.count)

                Text("Micronutrients come from the bundled USDA/Open Food Facts database. Values are hidden as unavailable unless the source food actually includes that nutrient.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var trendCard: some View {
        DetailCard(
            title: "7-Day Trend",
            subtitle: activeTrendSnapshots.isEmpty
                ? "No logged days in this window yet."
                : "Average is based on \(activeTrendSnapshots.count) logged day\(activeTrendSnapshots.count == 1 ? "" : "s") ending \(dateLabel.lowercased())."
        ) {
            VStack(spacing: 12) {
                TrendComparisonRow(title: "Calories", selected: totals.calories, average: trendAverage.calories, unit: "cal", tint: NomvaTheme.accent)
                TrendComparisonRow(title: "Protein", selected: totals.protein, average: trendAverage.protein, unit: "g", tint: NomvaTheme.macroProtein)
                TrendComparisonRow(title: "Fiber", selected: totals.fiber, average: trendAverage.fiber, unit: "g", tint: .teal)
                TrendComparisonRow(title: "Sodium", selected: totals.sodium, average: trendAverage.sodium, unit: "mg", tint: NomvaTheme.warning)
                TrendComparisonRow(title: "Added Sugar", selected: totals.addedSugar, average: trendAverage.addedSugar, unit: "g", tint: .pink)

                SevenDayMiniBars(snapshots: trendSnapshots, goalCalories: goal.calories)
                    .padding(.top, 4)
            }
        }
    }

    private var topSourcesCard: some View {
        DetailCard(
            title: "Top Contributors",
            subtitle: "The foods driving the biggest numbers for this day."
        ) {
            VStack(spacing: 14) {
                TopContributorGroup(title: "Calories", entries: topEntries(for: \.calories), value: { "\($0.calories.safeRoundedInt) cal" })
                TopContributorGroup(title: "Sodium", entries: topEntries(for: \.sodiumMg), value: { "\($0.sodiumMg.safeRoundedInt) mg" })
                TopContributorGroup(title: "Fiber", entries: topEntries(for: \.fiberG), value: { "\($0.fiberG.safeRoundedInt) g" })
                TopContributorGroup(title: "Saturated Fat", entries: topOptionalEntries(for: \.saturatedFatG), value: { "\(formattedOptional($0.saturatedFatG, unit: "g"))" })
                TopContributorGroup(title: "Potassium", entries: topOptionalEntries(for: \.potassiumMg), value: { "\(formattedOptional($0.potassiumMg, unit: "mg"))" })
            }
        }
    }

    private var dataQualityCard: some View {
        DetailCard(
            title: "Data Coverage",
            subtitle: "Nomva should be honest when food data is incomplete."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                CoverageRow(title: "Calories + macros", detail: "Available for logged foods", isAvailable: true)
                CoverageRow(title: "Fiber", detail: "Available when the source food includes it", isAvailable: entries.contains { $0.fiberG > 0 })
                CoverageRow(title: "Sodium + total sugar", detail: "Available for many packaged/database foods, but custom and photo foods may be blank", isAvailable: entries.contains { $0.sodiumMg > 0 || $0.sugarG > 0 })
                CoverageRow(title: "Added sugar, saturated fat, cholesterol", detail: coverageSummary(for: [\.addedSugarG, \.saturatedFatG, \.cholesterolMg]), isAvailable: hasKnownValue(for: \.addedSugarG) || hasKnownValue(for: \.saturatedFatG) || hasKnownValue(for: \.cholesterolMg))
                CoverageRow(title: "Vitamins + minerals", detail: coverageSummary(for: [\.vitaminDMcg, \.calciumMg, \.ironMg, \.potassiumMg]), isAvailable: hasKnownValue(for: \.vitaminDMcg) || hasKnownValue(for: \.calciumMg) || hasKnownValue(for: \.ironMg) || hasKnownValue(for: \.potassiumMg))
            }
        }
    }

    private func topEntries(for keyPath: KeyPath<FoodEntry, Double>) -> [FoodEntry] {
        entries
            .filter { $0[keyPath: keyPath] > 0 }
            .sorted { $0[keyPath: keyPath] > $1[keyPath: keyPath] }
            .prefix(3)
            .map { $0 }
    }

    private func topOptionalEntries(for keyPath: KeyPath<FoodEntry, Double?>) -> [FoodEntry] {
        entries
            .filter { ($0[keyPath: keyPath] ?? 0) > 0 }
            .sorted { ($0[keyPath: keyPath] ?? 0) > ($1[keyPath: keyPath] ?? 0) }
            .prefix(3)
            .map { $0 }
    }

    private func knownEntryCount(for keyPath: KeyPath<FoodEntry, Double?>) -> Int {
        entries.filter { $0[keyPath: keyPath] != nil }.count
    }

    private func hasKnownValue(for keyPath: KeyPath<FoodEntry, Double?>) -> Bool {
        knownEntryCount(for: keyPath) > 0
    }

    private func coverageSummary(for keyPaths: [KeyPath<FoodEntry, Double?>]) -> String {
        guard !entries.isEmpty else { return "No foods logged yet" }
        let foodsWithAnyValue = entries.filter { entry in
            keyPaths.contains { entry[keyPath: $0] != nil }
        }.count
        return "Known for \(foodsWithAnyValue) of \(entries.count) logged food\(entries.count == 1 ? "" : "s")"
    }

    private func formattedOptional(_ value: Double?, unit: String) -> String {
        guard let value else { return "Unknown" }
        if unit == "mg" || value >= 100 {
            return "\(value.safeRoundedInt) \(unit)"
        }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }

    private func progress(_ amount: Double, _ target: Double?) -> Double {
        guard let target, target > 0 else { return 0 }
        return min(max(amount / target, 0), 1.25)
    }

    private func dailyValueCue(amount: Double, target: Double, direction: NutrientDirection) -> String {
        guard target > 0 else { return "" }
        let percent = amount / target
        switch direction {
        case .target:
            if percent < 0.05 { return "Very low so far" }
            if percent >= 0.20 { return "Strong contribution" }
            return "Building toward target"
        case .limit:
            if percent <= 0.05 { return "Low so far" }
            if percent >= 0.20 { return "Worth watching" }
            return "Moderate so far"
        case .neutral:
            return ""
        }
    }
}

private struct DailyNutritionSnapshot: Identifiable {
    let date: Date
    let totals: NutritionTotals
    let entryCount: Int

    var id: Date { date }
}

private enum NutrientDirection {
    case target
    case limit
    case neutral
}

private struct DetailCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nomvaCard(.standard, padding: NomvaTheme.standardCardPadding)
    }
}

private struct OverviewPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
        .padding(.vertical, 10)
        .background(tint.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NutrientProgressRow: View {
    let title: String
    let amount: Double
    let unit: String
    let target: Double?
    let targetLabel: String?
    let tint: Color
    let direction: NutrientDirection
    var note: String? = nil

    private var percent: Double? {
        guard let target, target > 0 else { return nil }
        return amount / target
    }

    private var displayedTarget: String? {
        guard let target, let targetLabel else { return nil }
        return "\(formatted(target))\(unit) \(targetLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(formatted(amount))\(unit)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                    if let displayedTarget {
                        Text(displayedTarget)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressBar(progress: percent.map { min(max($0, 0), 1.25) } ?? 0, tint: barTint)

            if let percent {
                Text("\((percent * 100).safeRoundedInt)% \(targetLabel ?? "target")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var barTint: Color {
        guard let percent else { return tint.opacity(0.45) }
        switch direction {
        case .target:
            return percent > 1.05 ? NomvaTheme.success : tint
        case .limit:
            return percent > 1 ? NomvaTheme.danger : tint
        case .neutral:
            return tint
        }
    }

    private func formatted(_ value: Double) -> String {
        if value >= 100 || unit == "mg" || unit == "cal" {
            return "\(value.safeRoundedInt)"
        }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private struct TrackedNutrientProgressRow: View {
    let title: String
    let amount: Double
    let unit: String
    let target: Double
    let targetLabel: String
    let tint: Color
    let direction: NutrientDirection
    let knownCount: Int
    let totalCount: Int

    var body: some View {
        if knownCount == 0 {
            UnavailableNutrientRow(
                title: title,
                dailyValue: "\(formatted(target)) \(unit) \(targetLabel)"
            )
        } else {
            NutrientProgressRow(
                title: title,
                amount: amount,
                unit: unit,
                target: target,
                targetLabel: targetLabel,
                tint: tint,
                direction: direction,
                note: coverageNote
            )
        }
    }

    private var coverageNote: String {
        guard totalCount > 0 else { return "No foods logged yet" }
        if knownCount == totalCount {
            return "Known for all logged foods"
        }
        return "Known for \(knownCount) of \(totalCount) logged foods"
    }

    private func formatted(_ value: Double) -> String {
        if unit == "mg" || unit == "mcg" || value >= 100 {
            return "\(value.safeRoundedInt)"
        }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.13))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(proxy.size.width, proxy.size.width * progress)))
            }
        }
        .frame(height: 8)
    }
}

private struct UnavailableNutrientRow: View {
    let title: String
    let dailyValue: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(dailyValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Unavailable")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.60))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TrendComparisonRow: View {
    let title: String
    let selected: Double
    let average: Double
    let unit: String
    let tint: Color

    private var delta: Double { selected - average }
    private var maxValue: Double { max(selected, average, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(deltaText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(delta == 0 ? .secondary : delta > 0 ? tint : .secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                Text("Day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                ProgressBar(progress: selected / maxValue, tint: tint)
                Text("\(formatted(selected))\(unit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text("Avg")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                ProgressBar(progress: average / maxValue, tint: .secondary)
                Text("\(formatted(average))\(unit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    private var deltaText: String {
        guard average > 0 else { return "No avg yet" }
        let sign = delta >= 0 ? "+" : "-"
        return "\(sign)\(formatted(abs(delta)))\(unit) vs avg"
    }

    private func formatted(_ value: Double) -> String {
        unit == "mg" || unit == "cal" ? "\(value.safeRoundedInt)" : "\(value.safeRoundedInt)"
    }
}

private struct SevenDayMiniBars: View {
    let snapshots: [DailyNutritionSnapshot]
    let goalCalories: Double

    private var maxCalories: Double {
        max(goalCalories, snapshots.map { $0.totals.calories }.max() ?? 1, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(snapshots) { snapshot in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(snapshot.entryCount == 0 ? Color.secondary.opacity(0.18) : NomvaTheme.accent)
                        .frame(height: max(6, 58 * (snapshot.totals.calories / maxCalories)))
                    Text(dayLabel(snapshot.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 82)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Seven day calorie trend")
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date).prefix(1).uppercased()
    }
}

private struct TopContributorGroup: View {
    let title: String
    let entries: [FoodEntry]
    let value: (FoodEntry) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            if entries.isEmpty {
                Text("No \(title.lowercased()) sources logged yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(value(entry))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color(UIColor.secondarySystemBackground).opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        }
    }
}

private struct CoverageRow: View {
    let title: String
    let detail: String
    let isAvailable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isAvailable ? NomvaTheme.success : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
