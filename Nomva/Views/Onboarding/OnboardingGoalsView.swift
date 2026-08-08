import SwiftUI

struct OnboardingGoalsView: View {
    @Binding var weightGoal: WeightGoal
    let weightLbs: Double
    let heightInches: Int
    let age: Int
    let sex: BiologicalSex
    let activity: ActivityLevel

    var onContinue: (DailyGoal) -> Void
    var onSkip: () -> Void

    @State private var calorieGoal: Double = 2000
    @State private var proteinGoal: Double = 100
    @State private var carbGoal: Double = 250
    @State private var fatGoal: Double = 65

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Set your goals",
                subtitle: "Calculated from your profile and activity. You can adjust every target before continuing.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Goal", selection: $weightGoal) {
                        ForEach(WeightGoal.allCases, id: \.self) { goal in
                            Text(goal.displayName).tag(goal)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                    .onChange(of: weightGoal) { recalculateGoals() }

                    goalSummary
                }
            }

            OnboardingSectionCard(
                title: "Fine-tune the numbers",
                subtitle: "These targets shape your daily plan. You can change them later in Settings."
            ) {
                VStack(spacing: 14) {
                    GoalInputRow(
                        label: "Calories",
                        value: $calorieGoal,
                        unit: "kcal",
                        range: 1000...5000,
                        step: 10,
                        tint: NomvaTheme.accent
                    )

                    Divider()

                    GoalInputRow(
                        label: "Protein",
                        value: $proteinGoal,
                        unit: "g",
                        range: 40...400,
                        tint: NomvaTheme.macroProtein
                    )

                    Divider()

                    GoalInputRow(
                        label: "Carbs",
                        value: $carbGoal,
                        unit: "g",
                        range: 50...600,
                        tint: NomvaTheme.macroCarbs
                    )

                    Divider()

                    GoalInputRow(
                        label: "Fat",
                        value: $fatGoal,
                        unit: "g",
                        range: 20...200,
                        tint: NomvaTheme.macroFat
                    )
                }
            }
        } footer: {
            Button("Continue") {
                let goal = DailyGoal(
                    calories: calorieGoal,
                    protein: proteinGoal,
                    carbs: carbGoal,
                    fat: fatGoal
                )
                onContinue(goal)
            }
            .buttonStyle(NomvaPrimaryButtonStyle())

            Button("Use Defaults") {
                onSkip()
            }
            .buttonStyle(NomvaSecondaryButtonStyle())
        }
        .onAppear { recalculateGoals() }
    }

    private var goalSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(calorieGoal.safeRoundedInt.formatted())
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("kcal / day")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 0) {
                macroSummary(
                    title: "Protein",
                    value: proteinGoal.safeRoundedInt,
                    tint: NomvaTheme.macroProtein
                )

                Divider()
                    .frame(height: 42)

                macroSummary(
                    title: "Carbs",
                    value: carbGoal.safeRoundedInt,
                    tint: NomvaTheme.macroCarbs
                )

                Divider()
                    .frame(height: 42)

                macroSummary(
                    title: "Fat",
                    value: fatGoal.safeRoundedInt,
                    tint: NomvaTheme.macroFat
                )
            }
        }
    }

    private func macroSummary(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.formatted())
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("g")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    private func recalculateGoals() {
        let cal = GoalService.calculateSuggestedCalories(
            weightLbs: weightLbs,
            heightInches: heightInches,
            age: max(age, 18),
            sex: sex,
            activity: activity,
            goal: weightGoal
        )
        let macros = GoalService.suggestMacros(calories: cal, weightLbs: weightLbs, goal: weightGoal)
        calorieGoal = cal.rounded()
        proteinGoal = macros.protein.rounded()
        carbGoal = macros.carbs.rounded()
        fatGoal = macros.fat.rounded()
    }
}
