import SwiftUI

struct OnboardingCompleteView: View {
    var onStart: () -> Void

    @State private var showCheckmark = false

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "You're all set",
                subtitle: "Nomva is ready to help you log meals the easy way.",
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

                    Text("Just tell me what you ate, ask what you have left, or correct an entry in plain English.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            OnboardingSectionCard(
                title: "What you can do next",
                subtitle: "The core product is ready from the moment you land on the main tabs."
            ) {
                VStack(spacing: 14) {
                    OnboardingFeatureRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Log by talking",
                        detail: "Type a meal naturally instead of manually searching."
                    )
                    OnboardingFeatureRow(
                        icon: "slider.horizontal.3",
                        title: "Correct entries quickly",
                        detail: "Say things like “make that 3 eggs” and keep moving."
                    )
                    OnboardingFeatureRow(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "See your trends",
                        detail: "Watch calories, macros, water, and weight line up in one place."
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
