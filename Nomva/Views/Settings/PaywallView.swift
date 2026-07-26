import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject var subManager = SubscriptionManager.shared
    @Environment(\.dismiss) var dismiss

    private let privacyPolicyURL = URL(string: "https://nomva.nerdquad.com/privacy.html")!
    private let standardEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroCard

                    VStack(spacing: 14) {
                        featureCard(
                            icon: "brain.head.profile",
                            title: "Faster food logging",
                            desc: "Type meals the way you normally would."
                        )
                        featureCard(
                            icon: "wand.and.stars",
                            title: "Quick edits",
                            desc: "Fix an entry without starting over."
                        )
                        featureCard(
                            icon: "chart.line.uptrend.xyaxis",
                            title: "Trend summaries",
                            desc: "Check trends, calories left, and how your week is going."
                        )
                        featureCard(
                            icon: "cloud.fill",
                            title: "Nomva Cloud",
                            desc: "Runs AI features that need cloud processing."
                        )
                    }

                    pricingCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                if subManager.hasTestFlightAccess {
                    testFlightAccessControls
                } else {
                    purchaseControls
                }

                if subManager.remainingFreeMessages > 0 {
                    Text("You still have \(subManager.remainingFreeMessages) free messages.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Text("Cancel anytime.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        legalLink("Terms of Use", destination: standardEULAURL)
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        legalLink("Privacy Policy", destination: privacyPolicyURL)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
        .nomvaScreenBackground()
    }

    private var buttonTitle: String {
        if let product = subManager.product {
            return "Get Nomva Pro — \(product.displayPrice)/mo"
        }
        return "Loading pricing..."
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(NomvaTheme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Spacer()

                NomvaTag(
                    text: subManager.hasTestFlightAccess ? "TestFlight" : "Pro",
                    tint: subManager.hasTestFlightAccess ? .green : NomvaTheme.accent
                )
            }

            Text(subManager.hasTestFlightAccess ? "Nomva Pro is active" : "Unlock Nomva Pro")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text(
                subManager.hasTestFlightAccess
                    ? "This TestFlight build includes Pro access at no charge."
                    : "Get faster logging, easier edits, and premium insights."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                statPill("Faster logging")
                statPill("Quick edits")
                statPill("Insights")
            }
        }
        .nomvaCard(.hero, padding: 20)
    }

    private var pricingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subManager.hasTestFlightAccess ? "Included for beta testing" : "Included with Pro")
                .font(.headline)

            Text(
                subManager.hasTestFlightAccess
                    ? "All Pro features are unlocked while you test this build."
                    : "Unlimited AI logging, easier corrections, and premium insights."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if subManager.hasTestFlightAccess {
                Label("No purchase required", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else if let product = subManager.product {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(product.displayPrice)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("/ month")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Loading pricing...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .nomvaCard(.standard, padding: 20)
    }

    private var purchaseControls: some View {
        VStack(spacing: 12) {
            Button(action: purchase) {
                HStack(spacing: 10) {
                    if case .purchasing = subManager.purchaseState {
                        ProgressView().tint(.white)
                        Text("Processing...")
                    } else {
                        Text(buttonTitle)
                    }
                }
            }
            .buttonStyle(NomvaPrimaryButtonStyle())
            .disabled(subManager.product == nil || subManager.purchaseState.isBusy)

            Button {
                Task { await subManager.restore() }
            } label: {
                HStack(spacing: 8) {
                    if case .restoring = subManager.purchaseState {
                        ProgressView()
                        Text("Restoring...")
                    } else {
                        Text("Restore Purchases")
                    }
                }
            }
            .buttonStyle(NomvaSecondaryButtonStyle())
            .disabled(subManager.purchaseState.isBusy)

            if let message = subManager.purchaseState.feedbackMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(subManager.purchaseState.isError ? Color.red : Color.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var testFlightAccessControls: some View {
        VStack(spacing: 12) {
            Label("Pro is unlocked for this TestFlight build.", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)

            Button("Continue Testing") {
                dismiss()
            }
            .buttonStyle(NomvaPrimaryButtonStyle())
        }
    }

    private func featureCard(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(NomvaTheme.accent)
                .frame(width: 42, height: 42)
                .background(NomvaTheme.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .nomvaCard(.subtle, padding: 16)
    }

    private func statPill(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(NomvaTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(NomvaTheme.accent.opacity(0.10))
            .clipShape(Capsule())
    }

    private func purchase() {
        Task { await subManager.purchase() }
    }

    private func legalLink(_ title: String, destination: URL) -> some View {
        Link(title, destination: destination)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NomvaTheme.accent)
    }
}

#Preview {
    PaywallView()
}
