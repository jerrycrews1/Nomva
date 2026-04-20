import SwiftUI

struct OnboardingWelcomeView: View {
    var onContinue: () -> Void
    var onSkip: () -> Void

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Nomva",
                subtitle: "Track meals in plain English instead of digging through menus.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(NomvaTheme.accentGradient)

                        Spacer()

                        NomvaTag(text: "AI-first", tint: NomvaTheme.accent)
                    }

                    Text("Just say what you ate.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))

                    Text("Nomva helps you log, revise, and understand your day without making food tracking feel like paperwork.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            OnboardingSectionCard(
                title: "What gets easier",
                subtitle: "A quick setup gives the app context for smarter summaries."
            ) {
                VStack(spacing: 14) {
                    OnboardingFeatureRow(
                        icon: "message.badge.waveform",
                        title: "Natural meal logging",
                        detail: "Describe meals the way you actually think about them."
                    )
                    OnboardingFeatureRow(
                        icon: "slider.horizontal.3",
                        title: "Personalized targets",
                        detail: "Use your body info to estimate calories and macros that fit you."
                    )
                    OnboardingFeatureRow(
                        icon: "icloud",
                        title: "Optional sync",
                        detail: "Keep your data private on-device or sync across Apple devices."
                    )
                }
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
