import SwiftUI

struct MacroRingsView: View {
    let consumed: NutritionTotals
    let goal: DailyGoal
    var isCompact: Bool = false
    var showsDetailCue: Bool = false

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
        .accessibilityLabel("Nutrition summary: \(consumed.calories.safeRoundedInt) of \(goal.calories.safeRoundedInt) calories")
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
                HStack(spacing: 8) {
                    compactMacro(label: "P", val: consumed.protein, color: .blue)
                    compactMacro(label: "C", val: consumed.carbs, color: .green)
                    compactMacro(label: "F", val: consumed.fat, color: .yellow)
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

                    Text("Calories and macros update live as you log.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                NomvaTag(
                    text: calorieStatus,
                    tint: remainingCalories > 0 ? NomvaTheme.accent : .green
                )

                if showsDetailCue {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
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
                        color: .blue,
                        unit: "g"
                    )

                    MacroBarView(
                        label: "Carbs",
                        consumed: consumed.carbs,
                        goal: goal.carbs,
                        color: .green,
                        unit: "g"
                    )

                    MacroBarView(
                        label: "Fat",
                        consumed: consumed.fat,
                        goal: goal.fat,
                        color: .yellow,
                        unit: "g"
                    )
                }
            }

            HStack(spacing: 10) {
                MacroStatPill(label: "Protein", value: consumed.protein.safeRoundedInt, tint: .blue)
                MacroStatPill(label: "Carbs", value: consumed.carbs.safeRoundedInt, tint: .green)
                MacroStatPill(label: "Fat", value: consumed.fat.safeRoundedInt, tint: .yellow)
            }
        }
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
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
                    progress > 1 ? Color.red : color,
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
                        .fill(consumed > goal ? Color.red : color)
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
