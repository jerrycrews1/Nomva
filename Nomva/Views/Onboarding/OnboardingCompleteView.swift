import SwiftUI

struct OnboardingCompleteView: View {
    var onStart: () -> Void

    @State private var showCheckmark = false

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "You're all set",
                subtitle: "You can start logging right away.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 92, height: 92)

                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 56))
                                .foregroundColor(.green)
                                .scaleEffect(showCheckmark ? 1.0 : 0.3)
                                .opacity(showCheckmark ? 1.0 : 0)
                                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
                        }

                        Spacer()

                        NomvaTag(text: "Ready", tint: .green)
                    }

                    Text("Log a meal, check what's left, or fix an entry without leaving the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            OnboardingSectionCard(
                title: "What you can do next",
                subtitle: "A few places to start."
            ) {
                VStack(spacing: 14) {
                    OnboardingFeatureRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Log by talking",
                        detail: "Type your meal instead of searching for every item."
                    )
                    OnboardingFeatureRow(
                        icon: "slider.horizontal.3",
                        title: "Correct entries quickly",
                        detail: "Make quick fixes like \"change that to 3 eggs.\""
                    )
                    OnboardingFeatureRow(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "See your trends",
                        detail: "Check calories, macros, water, and weight in one place."
                    )
                }
            }
        } footer: {
            Button("Start Tracking") {
                onStart()
            }
            .buttonStyle(NomvaPrimaryButtonStyle())
        }
        .onAppear {
            withAnimation {
                showCheckmark = true
            }
        }
    }
}

#Preview {
    OnboardingCompleteView(onStart: {})
}
