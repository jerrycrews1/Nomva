import SwiftUI

struct OnboardingWelcomeView: View {
    var onContinue: () -> Void
    var onSkip: () -> Void

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Nomva",
                subtitle: "Log meals faster.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(NomvaTheme.accentGradient)

                        Spacer()
                    }

                    Text("Just say what you ate.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))

                    Text("Log food, fix entries, and keep an eye on your day without turning tracking into busywork.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            OnboardingSectionCard(
                title: "What gets easier",
                subtitle: "A quick setup gives your daily targets a better starting point."
            ) {
                VStack(spacing: 14) {
                    OnboardingFeatureRow(
                        icon: "message.badge.waveform",
                        title: "Natural meal logging",
                        detail: "Describe a meal the way you'd normally type it."
                    )
                    OnboardingFeatureRow(
                        icon: "slider.horizontal.3",
                        title: "Personalized targets",
                        detail: "Adults can review general calorie and macro estimates. These are not medical advice."
                    )
                    OnboardingFeatureRow(
                        icon: "icloud",
                        title: "Optional sync",
                        detail: "Keep your history on this device. Sync weigh-ins through Apple Health."
                    )
                }
                Text("If you are under 18 or have special nutritional needs, skip the calorie planner and ask a qualified clinician before choosing a target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Button("Get Started") {
                onContinue()
            }
            .buttonStyle(NomvaPrimaryButtonStyle())

            Button("Skip Setup") {
                onSkip()
            }
            .buttonStyle(NomvaSecondaryButtonStyle())
        }
    }
}

#Preview {
    OnboardingWelcomeView(onContinue: {}, onSkip: {})
}
