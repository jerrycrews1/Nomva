import SwiftUI

struct ActivityGoalSnapshot {
    let sourceName: String
    let activeCalories: Double?
    let baselineCalories: Double?
    let earnedCalories: Double
    let goalAdjustmentCalories: Double
    let isToday: Bool
    let isSyncing: Bool
    let affectsGoal: Bool

    var activeText: String {
        if let activeCalories {
            return "\(activeCalories.safeRoundedInt) active kcal"
        }
        if isSyncing {
            return "Syncing activity"
        }
        if let baselineCalories {
            return "\(baselineCalories.safeRoundedInt) avg active kcal"
        }
        return "Activity unavailable"
    }

    var sourceDetailText: String {
        if let baselineCalories {
            return "\(sourceName) active-calorie estimate • \(baselineCalories.safeRoundedInt)-kcal recent baseline"
        }
        return "\(sourceName) active-calorie estimate"
    }

    var compactImpactText: String {
        guard affectsGoal else { return "not in target" }
        if isToday {
            if activeCalories == nil { return isSyncing ? "syncing" : "waiting today" }
            if earnedCalories > 0 { return "+\(earnedCalories.safeRoundedInt) to target" }
            if let baselineCalories { return "\(baselineCalories.safeRoundedInt) baseline" }
            return "no baseline"
        }

        let adjustment = goalAdjustmentCalories.safeRoundedInt
        if adjustment > 0 { return "+\(adjustment) to target" }
        if adjustment < 0 { return "\(adjustment) target" }
        return "baseline matched"
    }

    var targetImpactText: String {
        guard affectsGoal else {
            return "This activity source is not being used for your calorie target."
        }
        if isToday {
            if activeCalories == nil {
                return isSyncing
                    ? "Syncing today's activity now."
                    : "Waiting for today's activity to sync."
            }
            if earnedCalories > 0 {
                return "\(earnedCalories.safeRoundedInt) kcal above baseline adds the same amount to today's target."
            }
            if let baselineCalories {
                return "Today's target already includes the \(baselineCalories.safeRoundedInt)-kcal baseline. Extra calories are added after activity passes it."
            }
            return "Nomva needs a completed-day baseline before activity can adjust the target."
        }

        let adjustment = goalAdjustmentCalories.safeRoundedInt
        if adjustment > 0 { return "Activity added \(adjustment) kcal to this day's target." }
        if adjustment < 0 { return "Activity reduced this day's target by \(abs(adjustment)) kcal." }
        return "Activity matched the calorie-target baseline for this day."
    }
}

struct MacroRingsView: View {
    let consumed: NutritionTotals
    let goal: DailyGoal
    var isCompact: Bool = false
    var showsDetailCue: Bool = false
    var activity: ActivityGoalSnapshot? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calorieProgress: Double {
        goal.calories > 0 ? consumed.calories / goal.calories : 0
    }

    private var remainingCalories: Int {
        max((goal.calories - consumed.calories).safeRoundedInt, 0)
    }

    private var calorieStatus: String {
        remainingCalories > 0 ? "\(remainingCalories) cal left" : "Goal reached"
    }

    var body: some View {
        Group {
            if isCompact {
                compactSummary
            } else {
                expandedSummary
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var summary = "Nutrition summary: \(consumed.calories.safeRoundedInt) of \(goal.calories.safeRoundedInt) calories"
        if let activity {
            summary += ", \(activity.activeText), \(activity.targetImpactText)"
        }
        return summary
    }

    private var compactSummary: some View {
        HStack(spacing: 14) {
            RingView(
                progress: calorieProgress,
                label: "\(consumed.calories.safeRoundedInt)",
                sublabel: "cal",
                color: NomvaTheme.accent,
                size: 56
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(calorieStatus)
                    .font(.subheadline.weight(.semibold))

                if let activity {
                    activityCompactRow(activity)
                }

                HStack(spacing: 8) {
                    compactMacro(label: "P", val: consumed.protein, color: NomvaTheme.macroProtein)
                    compactMacro(label: "C", val: consumed.carbs, color: NomvaTheme.macroCarbs)
                    compactMacro(label: "F", val: consumed.fat, color: NomvaTheme.macroFat)
                }
            }

            Spacer()

            if showsDetailCue {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
    }

    private var expandedSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)

                    Text("Nutrition Snapshot")
                        .font(.title3.weight(.semibold))

                    Text(activity == nil
                        ? "Calories and macros update live as you log."
                        : "Food and synced activity update your daily target.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                NomvaTag(
                    text: calorieStatus,
                    tint: remainingCalories > 0 ? NomvaTheme.accent : NomvaTheme.success
                )

                if showsDetailCue {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }

            if let activity {
                Divider()
                activityExpandedRow(activity)
            }

            HStack(spacing: 20) {
                RingView(
                    progress: calorieProgress,
                    label: "\(consumed.calories.safeRoundedInt)",
                    sublabel: "of \(goal.calories.safeRoundedInt)",
                    color: NomvaTheme.accent,
                    size: 104
                )
                .animation(
                    reduceMotion ? .none : .spring(response: 0.5, dampingFraction: 0.7),
                    value: consumed.calories
                )

                VStack(spacing: 12) {
                    MacroBarView(
                        label: "Protein",
                        consumed: consumed.protein,
                        goal: goal.protein,
                        color: NomvaTheme.macroProtein,
                        unit: "g"
                    )

                    MacroBarView(
                        label: "Carbs",
                        consumed: consumed.carbs,
                        goal: goal.carbs,
                        color: NomvaTheme.macroCarbs,
                        unit: "g"
                    )

                    MacroBarView(
                        label: "Fat",
                        consumed: consumed.fat,
                        goal: goal.fat,
                        color: NomvaTheme.macroFat,
                        unit: "g"
                    )
                }
            }

            HStack(spacing: 10) {
                MacroStatPill(label: "Protein", value: consumed.protein.safeRoundedInt, tint: NomvaTheme.macroProtein)
                MacroStatPill(label: "Carbs", value: consumed.carbs.safeRoundedInt, tint: NomvaTheme.macroCarbs)
                MacroStatPill(label: "Fat", value: consumed.fat.safeRoundedInt, tint: NomvaTheme.macroFat)
            }
        }
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    private func activityCompactRow(_ activity: ActivityGoalSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "figure.walk.motion")
                .foregroundStyle(NomvaTheme.accent)
            Text(activity.activeText)
            Text("•")
                .foregroundStyle(.tertiary)
            Text(activity.compactImpactText)
                .foregroundStyle(activity.earnedCalories > 0 ? NomvaTheme.success : Color.secondary)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func activityExpandedRow(_ activity: ActivityGoalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk.motion")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(NomvaTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(NomvaTheme.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.isToday ? "Activity today" : "Activity")
                        .font(.subheadline.weight(.semibold))
                    Text(activity.sourceDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(activity.activeText)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }

            Text(activity.targetImpactText)
                .font(.caption)
                .foregroundStyle(activity.earnedCalories > 0 ? NomvaTheme.success : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compactMacro(label: String, val: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundColor(color)

            Text("\(val.safeRoundedInt)g")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
        .padding(.vertical, NomvaTheme.chipVerticalPadding)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }
}

struct RingView: View {
    let progress: Double
    let label: String
    let sublabel: String
    let color: Color
    let size: CGFloat

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.14), lineWidth: size * 0.12)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    progress > 1 ? NomvaTheme.danger : color,
                    style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)

                Text(sublabel)
                    .font(.system(size: size * 0.13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct MacroBarView: View {
    let label: String
    let consumed: Double
    let goal: Double
    let color: Color
    let unit: String

    private var progress: Double {
        goal > 0 ? min(consumed / goal, 1) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(consumed.safeRoundedInt) / \(goal.safeRoundedInt)\(unit)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.15))
                        .frame(height: 8)

                    Capsule()
                        .fill(consumed > goal ? NomvaTheme.danger : color)
                        .frame(width: geo.size.width * progress, height: 8)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(consumed.safeRoundedInt) of \(goal.safeRoundedInt) grams")
    }
}

private struct MacroStatPill: View {
    let label: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(value)g")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    MacroRingsView(
        consumed: NutritionTotals(calories: 1400, protein: 90, carbs: 180, fat: 45),
        goal: DailyGoal(calories: 2000, protein: 150, carbs: 250, fat: 65)
    )
    .padding()
}
