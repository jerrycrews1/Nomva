import SwiftUI

enum NomvaTheme {
    // Text and controls need opposite luminance shifts in light and dark mode.
    // Keep these separate from accentGradient, whose white label requires a
    // consistently dark fill in both appearances.
    static let accent = adaptive(
        light: UIColor(red: 0.60, green: 0.24, blue: 0.00, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.67, blue: 0.36, alpha: 1)
    )
    static let accentFill = Color(red: 0.72, green: 0.27, blue: 0.00)
    static let accentStrong = Color(red: 0.56, green: 0.19, blue: 0.00)
    static let onAccent = Color.white
    static let accentSoft = adaptive(
        light: UIColor(red: 1.00, green: 0.82, blue: 0.60, alpha: 1),
        dark: UIColor(red: 0.36, green: 0.17, blue: 0.05, alpha: 1)
    )

    static let success = adaptive(
        light: UIColor(red: 0.09, green: 0.48, blue: 0.22, alpha: 1),
        dark: UIColor(red: 0.38, green: 0.85, blue: 0.53, alpha: 1)
    )
    static let warning = adaptive(
        light: UIColor(red: 0.54, green: 0.28, blue: 0.00, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.71, blue: 0.37, alpha: 1)
    )
    static let info = adaptive(
        light: UIColor(red: 0.04, green: 0.38, blue: 0.78, alpha: 1),
        dark: UIColor(red: 0.40, green: 0.69, blue: 1.00, alpha: 1)
    )
    static let infoFill = Color(red: 0.04, green: 0.38, blue: 0.78)
    static let danger = adaptive(
        light: UIColor(red: 0.74, green: 0.12, blue: 0.18, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.42, blue: 0.45, alpha: 1)
    )
    static let macroProtein = info
    static let macroCarbs = success
    static let macroFat = warning
    
    // Adaptive colors
    static let mist = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor.systemGray6 : UIColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1.0)
    })
    static let warm = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor.black : UIColor(red: 0.99, green: 0.95, blue: 0.90, alpha: 1.0)
    })
    static let mint = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor.systemTeal.withAlphaComponent(0.1) : UIColor(red: 0.91, green: 0.98, blue: 0.95, alpha: 1.0)
    })
    
    static let line = Color.primary.opacity(0.12)
    static let shadow = Color.black.opacity(0.10)
    static let screenInset: CGFloat = 10
    static let contentInset: CGFloat = screenInset
    static let sectionGap: CGFloat = 12
    static let topCardGap: CGFloat = 12
    static let pageTopGap: CGFloat = 20
    static let primaryControlHeight: CGFloat = 52
    static let secondaryControlHeight: CGFloat = 46
    static let iconControlSize: CGFloat = 40
    static let heroCardPadding: CGFloat = 18
    static let standardCardPadding: CGFloat = 16
    static let chipHorizontalPadding: CGFloat = 12
    static let chipVerticalPadding: CGFloat = 6
    static let toolbarHorizontalPadding: CGFloat = 14
    static let sectionHeaderLeadingInset: CGFloat = screenInset + 4
    static let bottomBarTopInset: CGFloat = 8
    static let bottomBarBottomInset: CGFloat = 10

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let accentGradient = LinearGradient(
        colors: [accentFill, accentStrong],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let screenGradient = LinearGradient(
        colors: [warm, mist],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [
            Color(UIColor.secondarySystemBackground).opacity(0.96),
            Color(UIColor.secondarySystemBackground).opacity(0.82)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [
            Color(UIColor.secondarySystemBackground).opacity(0.94),
            accentSoft.opacity(0.22),
            mint.opacity(0.16)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct NomvaScreenBackground: View {
    var body: some View {
        ZStack {
            NomvaTheme.screenGradient

            Circle()
                .fill(NomvaTheme.accentSoft.opacity(0.20))
                .frame(width: 280, height: 280)
                .blur(radius: 12)
                .offset(x: 140, y: -220)

            Circle()
                .fill(NomvaTheme.mint.opacity(0.22))
                .frame(width: 240, height: 240)
                .blur(radius: 18)
                .offset(x: -150, y: 300)
        }
        .ignoresSafeArea()
    }
}

enum NomvaCardTone {
    case standard
    case hero
    case subtle
}

struct NomvaCardModifier: ViewModifier {
    let tone: NomvaCardTone
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(NomvaTheme.line, lineWidth: 1)
            )
            .shadow(color: NomvaTheme.shadow, radius: 18, x: 0, y: 12)
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch tone {
        case .standard:
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(NomvaTheme.cardGradient)
        case .hero:
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(NomvaTheme.heroGradient)
        case .subtle:
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.72))
        }
    }
}

extension View {
    func nomvaScreenBackground() -> some View {
        background(NomvaScreenBackground())
    }

    func nomvaCard(_ tone: NomvaCardTone = .standard, padding: CGFloat = 18) -> some View {
        modifier(NomvaCardModifier(tone: tone, padding: padding))
    }

    func nomvaToolbarChrome(horizontalPadding: CGFloat = NomvaTheme.toolbarHorizontalPadding) -> some View {
        modifier(NomvaToolbarChromeModifier(horizontalPadding: horizontalPadding))
    }

    func nomvaSectionHeaderPadding(top: CGFloat = 8, bottom: CGFloat = 4) -> some View {
        padding(.horizontal, NomvaTheme.sectionHeaderLeadingInset)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

struct NomvaPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(NomvaTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: NomvaTheme.primaryControlHeight)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(NomvaTheme.accentGradient)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .shadow(color: NomvaTheme.accent.opacity(0.28), radius: 16, x: 0, y: 10)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct NomvaSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: NomvaTheme.secondaryControlHeight)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground).opacity(configuration.isPressed ? 0.84 : 0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(NomvaTheme.line, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct NomvaSectionLabel: View {
    let eyebrow: String
    let title: String
    let detail: String?

    init(_ eyebrow: String, title: String, detail: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Text(title)
                .font(.title3.weight(.semibold))

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NomvaSectionHeaderText: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
    }
}

struct NomvaTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
            .padding(.vertical, NomvaTheme.chipVerticalPadding)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }
}

private struct NomvaToolbarChromeModifier: ViewModifier {
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: NomvaTheme.secondaryControlHeight)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(NomvaTheme.line, lineWidth: 1)
            )
    }
}

struct NomvaDateNavigator: View {
    let label: String
    let isCurrent: Bool
    let canAdvance: Bool
    let onPrevious: () -> Void
    let onJumpToCurrent: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.bold())
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Previous day")

            Button(action: onJumpToCurrent) {
                Text(label)
                    .font(.subheadline.bold())
                    .frame(minWidth: 116)
            }
            .foregroundStyle(isCurrent ? NomvaTheme.accent : Color.primary)

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .frame(width: 28, height: 28)
                    .foregroundStyle(canAdvance ? Color.primary : Color.secondary.opacity(0.3))
            }
            .disabled(!canAdvance)
            .accessibilityLabel("Next day")
        }
        .nomvaToolbarChrome()
    }
}

struct NomvaBottomActionBar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, NomvaTheme.screenInset)
            .padding(.top, NomvaTheme.bottomBarTopInset)
            .padding(.bottom, NomvaTheme.bottomBarBottomInset)
            .background(.ultraThinMaterial)
    }
}
