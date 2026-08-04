import SwiftUI

struct UnpersonalizedGoalsBanner: View {
    @EnvironmentObject private var routeCenter: NomvaRouteCenter
    @AppStorage("onboarding_complete") private var onboardingComplete = false
    @AppStorage("goals_personalized") private var goalsPersonalized = false
    @State private var isDismissed = false

    var shouldShow: Bool {
        onboardingComplete && !goalsPersonalized && !isDismissed
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 12) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.title3)
                    .foregroundColor(NomvaTheme.info)
                    .padding(8)
                    .background(NomvaTheme.info.opacity(0.10))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Using default goals")
                        .font(.subheadline.weight(.semibold))
                    Text("Personalize your calorie and macro targets in Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(spacing: 8) {
                    Button("Set Up") {
                        routeCenter.handle(url: NomvaWidgetRoute.goals.url)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NomvaTheme.accent)

                    Button {
                        isDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
            .nomvaCard(.subtle, padding: 16)
        }
    }
}

#Preview {
    UnpersonalizedGoalsBanner()
        .padding()
        .environmentObject(NomvaRouteCenter.shared)
}
