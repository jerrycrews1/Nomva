import SwiftUI

struct OnboardingiCloudView: View {
    var onContinue: () -> Void
    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Your history stays on this device",
                subtitle: "No Nomva cloud account is needed to sync weigh-ins.",
                tone: .hero
            ) {
                Label("Protected on-device storage", systemImage: "iphone")
                    .font(.headline)
                Text("Food logs, water, goals, and chat history are saved here. AI food requests are sent for processing when you use AI features.")
                    .foregroundStyle(.secondary)
            }
            OnboardingSectionCard(
                title: "Weight sync through Apple Health",
                subtitle: "Set up Weight Sync in Settings when you are ready."
            ) {
                Text("Garmin Connect → Apple Health → Nomva")
                    .font(.headline)
                Text("You can also save Nomva weigh-ins to Apple Health. To see them on another Apple device, enable Health in iCloud and allow Nomva to read Weight there.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Button("Continue", action: onContinue)
                .buttonStyle(NomvaPrimaryButtonStyle())
        }
    }
}
