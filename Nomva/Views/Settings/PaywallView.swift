import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject var subManager = SubscriptionManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroCard

                    VStack(spacing: 14) {
                        featureCard(
                            icon: "brain.head.profile",
                            title: "Smart AI Logging",
                            desc: "Describe meals naturally and skip the tedious search flow."
                        )
                        featureCard(
                            icon: "wand.and.stars",
                            title: "Natural Language Editing",
                            desc: "Fix entries the same way you talk: “Actually, make that 3 eggs.”"
                        )
                        featureCard(
                            icon: "chart.line.uptrend.xyaxis",
                            title: "Deep Health Insights",
                            desc: "Ask about trends, calories left, or how your habits are stacking up."
                        )
                        featureCard(
                            icon: "cloud.fill",
                            title: "Nomva Cloud",
                            desc: "Keep AI features available even when on-device models are limited."
                        )
                    }

                    pricingCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                Button(action: purchase) {
                    HStack(spacing: 10) {
                        switch subManager.purchaseState {
                        case .purchasing:
                            ProgressView().tint(.white)
                            Text("Processing...")
                        case .error(let msg):
                            Text(msg)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        default:
                            Text(buttonTitle)
                        }
                    }
                }
                .buttonStyle(NomvaPrimaryButtonStyle())
                .disabled(subManager.product == nil || !subManager.purchaseState.isIdle)

                Button("Restore Purchases") {
                    Task { await subManager.restore() }
                }
                .buttonStyle(NomvaSecondaryButtonStyle())

                if subManager.remainingFreeMessages > 0 {
                    Text("Or start with \(subManager.remainingFreeMessages) free messages.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text("Cancel anytime. Terms and Privacy apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

                NomvaTag(text: "Pro", tint: NomvaTheme.accent)
            }

            Text("Unlock Nomva Pro")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text("Make the app feel like a real nutrition copilot instead of a basic logbook.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                statPill("AI logging")
                statPill("Corrections")
                statPill("Insights")
            }
        }
        .nomvaCard(.hero, padding: 20)
    }

    private var pricingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Included with Pro")
                .font(.headline)

            Text("Unlimited AI-first food logging, better edit flows, and cloud-backed intelligence when you need it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let product = subManager.product {
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
}

#Preview {
    PaywallView()
}
