import SwiftUI
import SwiftData

struct OnboardingCoordinatorView: View {
    @State private var currentStep: OnboardingStep = .welcome
    @Environment(\.modelContext) private var modelContext
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome, basics, goals, iCloud, allSet
    }

    // Collected data passed between steps
    @State private var biologicalSex: BiologicalSex = .notSpecified
    @State private var birthYear: Int = Calendar.current.component(.year, from: Date()) - 30
    @State private var heightFeet: Int = 5
    @State private var heightInches: Int = 9
    @State private var currentWeightLbs: Double = 160
    @State private var activityLevel: ActivityLevel = .moderatelyActive
    @State private var weightGoal: WeightGoal = .maintain

    private var stepIndex: Int {
        OnboardingStep.allCases.firstIndex(of: currentStep) ?? 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NomvaScreenBackground()

                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Setup")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.6)

                            Spacer()

                            Text("Step \(stepIndex + 1) of \(OnboardingStep.allCases.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: Double(stepIndex + 1), total: Double(OnboardingStep.allCases.count))
                            .tint(NomvaTheme.accent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Group {
                        switch currentStep {
                        case .welcome:
                            OnboardingWelcomeView(
                                onContinue: { advance() },
                                onSkip: { skipAll() }
                            )
                        case .basics:
                            OnboardingBasicsView(
                                biologicalSex: $biologicalSex,
                                birthYear: $birthYear,
                                heightFeet: $heightFeet,
                                heightInches: $heightInches,
                                currentWeightLbs: $currentWeightLbs,
                                activityLevel: $activityLevel,
                                onContinue: { advance() },
                                onSkip: { advance() }
                            )
                        case .goals:
                            OnboardingGoalsView(
                                weightGoal: $weightGoal,
                                weightLbs: currentWeightLbs,
                                heightInches: heightFeet * 12 + heightInches,
                                age: Calendar.current.component(.year, from: Date()) - birthYear,
                                sex: biologicalSex,
                                activity: activityLevel,
                                onContinue: { goal in
                                    saveGoal(goal)
                                    advance()
                                },
                                onSkip: {
                                    saveDefaultGoal()
                                    advance()
                                }
                            )
                        case .iCloud:
                            OnboardingiCloudView(
                                onContinue: { advance() }
                            )
                        case .allSet:
                            OnboardingCompleteView(onStart: {
                                saveProfile()
                                onboardingComplete = true
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .animation(.easeInOut, value: currentStep)
        }
    }

    private func advance() {
        guard let idx = OnboardingStep.allCases.firstIndex(of: currentStep),
              idx + 1 < OnboardingStep.allCases.count else { return }
        currentStep = OnboardingStep.allCases[idx + 1]
    }

    private func skipAll() {
        saveDefaultGoal()
        UserDefaults.standard.set(true, forKey: "onboarding_complete")
        onboardingComplete = true
    }

    private func saveGoal(_ goal: DailyGoal) {
        modelContext.insert(goal)
    }

    private func saveDefaultGoal() {
        let goal = GoalService.defaultGoal()
        modelContext.insert(goal)
    }

    private func saveProfile() {
        let profile = UserProfile(
            biologicalSex: biologicalSex.rawValue,
            birthYear: birthYear,
            heightInches: heightFeet * 12 + heightInches,
            activityLevel: activityLevel.rawValue,
            weightGoal: weightGoal.rawValue
        )
        profile.onboardingComplete = true
        modelContext.insert(profile)

        if currentWeightLbs > 0 {
            let weightEntry = WeightEntry(weightLbs: currentWeightLbs)
            modelContext.insert(weightEntry)
        }
    }
}
