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
                subtitle: "These are your starting targets. You can adjust them later or use Apple Health instead.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Goal", selection: $weightGoal) {
                        ForEach(WeightGoal.allCases, id: \.self) { goal in
                            Text(goal.displayName).tag(goal)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: weightGoal) { recalculateGoals() }

                    HStack(spacing: 12) {
                        goalPreviewTile(title: "Calories", value: "\(Int(calorieGoal))", unit: "kcal", tint: NomvaTheme.accent)
                        goalPreviewTile(title: "Protein", value: "\(Int(proteinGoal))", unit: "g", tint: .blue)
                        goalPreviewTile(title: "Carbs", value: "\(Int(carbGoal))", unit: "g", tint: .green)
                        goalPreviewTile(title: "Fat", value: "\(Int(fatGoal))", unit: "g", tint: .yellow)
                    }
                }
            }

            OnboardingSectionCard(
                title: "Fine-tune the numbers",
                subtitle: "Adjust them now if you want. You can change them later in Settings."
            ) {
                VStack(spacing: 18) {
                    GoalInputRow(label: "Calories", value: $calorieGoal, unit: "kcal", range: 1000...5000)
                    GoalInputRow(label: "Protein", value: $proteinGoal, unit: "g", range: 40...400)
                    GoalInputRow(label: "Carbs", value: $carbGoal, unit: "g", range: 50...600)
                    GoalInputRow(label: "Fat", value: $fatGoal, unit: "g", range: 20...200)
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

    private func goalPreviewTile(title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.75)
            Text(unit)
                .font(.caption)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
