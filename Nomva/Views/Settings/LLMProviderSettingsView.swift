import SwiftUI

struct LLMProviderSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "cloud.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nomva Cloud")
                            .font(.subheadline.weight(.medium))
                        Text("Powered by GPT-4o-mini")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                }
                .padding(.vertical, 4)
            } header: {
                Text("AI Provider")
            } footer: {
                Text("AI features use Nomva Cloud and need an internet connection.")
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cloud Processing")
                            .font(.subheadline.bold())
                        Text("Messages go through Nomva's server for processing. Food logs stay on your device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("AI Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}
