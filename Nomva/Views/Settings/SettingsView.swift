import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var garminManager: GarminManager
    @State private var dbMetadata: (totalFoods: Int, buildDate: String) = (0, "Unknown")
    @State private var showPaywallPreview = false

    @State private var isPremiumLocal: Bool = UserDefaults.standard.bool(forKey: "is_premium_dev_override")
    @AppStorage("show_debug_tools") private var showDebugTools = false
    private let contentInset: CGFloat = NomvaTheme.contentInset

    var body: some View {
        NavigationStack {
            ZStack {
                NomvaScreenBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: NomvaTheme.sectionGap) {
                        aiOverviewCard

                        SettingsSectionCard("Nutrition", detail: "Adjust the targets that power your log and daily summaries, including Apple Health-based goal suggestions.") {
                            NavigationLink {
                                GoalsSettingsView()
                            } label: {
                                SettingsLinkRow(
                                    icon: "target",
                                    title: "Goals",
                                    subtitle: "Calories, macros, and activity source"
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        SettingsSectionCard("Integrations", detail: "Connect activity sources that can personalize your calorie targets and daily summaries.") {
                            NavigationLink {
                                GarminSettingsDetailView()
                            } label: {
                                SettingsLinkRow(
                                    icon: "dot.radiowaves.left.and.right",
                                    title: "Garmin Connect",
                                    subtitle: garminSubtitle
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        SettingsSectionCard("Data", detail: "Keep your food library and sync preferences easy to find.") {
                            VStack(spacing: 12) {
                                NavigationLink {
                                    iCloudSyncSettingsView()
                                } label: {
                                    SettingsLinkRow(
                                        icon: "icloud",
                                        title: "iCloud Sync",
                                        subtitle: "Private cross-device syncing"
                                    )
                                }
                                .buttonStyle(.plain)

                                NavigationLink {
                                    CustomFoodsListView()
                                } label: {
                                    SettingsLinkRow(
                                        icon: "square.grid.2x2",
                                        title: "Custom Foods",
                                        subtitle: "Manage foods you created"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        SettingsSectionCard("Membership", detail: "Restore purchases or confirm that premium features are active.") {
                            VStack(spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Nomva Pro")
                                            .font(.headline)
                                        Text(membershipSubtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    NomvaTag(
                                        text: membershipStatus,
                                        tint: isPremiumLocal ? .green : NomvaTheme.accent
                                    )
                                }

                                HStack(spacing: 12) {
                                    Button("Restore Purchases") {
                                        Task { await SubscriptionManager.shared.restore() }
                                    }
                                    .buttonStyle(NomvaSecondaryButtonStyle())

                                    Button("View Pro Screen") {
                                        showPaywallPreview = true
                                    }
                                    .buttonStyle(NomvaSecondaryButtonStyle())
                                }
                            }
                        }

                        if showDebugTools {
                            SettingsSectionCard("Developer Tools", detail: "Hidden by default so the customer-facing settings stay clean.") {
                                VStack(spacing: 14) {
                                    Toggle("Pro Status Override", isOn: $isPremiumLocal)
                                        .onChange(of: isPremiumLocal) { _, newValue in
                                            UserDefaults.standard.set(newValue, forKey: "is_premium_dev_override")
                                        }

                                    Button("Seed Data for Screenshots") {
                                        SeedData.seedAppStoreData(context: modelContext)
                                    }
                                    .buttonStyle(NomvaSecondaryButtonStyle())
                                }
                            }
                        }

                        SettingsSectionCard("Backup & Export", detail: "Export your data for backup or share reports with your coach.") {
                            NavigationLink {
                                ExportSettingsView()
                            } label: {
                                SettingsLinkRow(
                                    icon: "square.and.arrow.up",
                                    title: "Backup & Export Data",
                                    subtitle: "CSV Reports and JSON Backups"
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        SettingsSectionCard("Food Database", detail: "Reference info for the local nutrition catalog bundled with the app.") {
                            HStack(spacing: 12) {
                                SettingsStatTile(
                                    title: "Total Foods",
                                    value: dbMetadata.totalFoods > 0 ? dbMetadata.totalFoods.formatted() : "Loading…"
                                )

                                SettingsStatTile(
                                    title: "Last Updated",
                                    value: dbMetadata.buildDate
                                )
                            }
                        }

                        SettingsSectionCard("About", detail: "Legal links and build info.") {
                            VStack(spacing: 12) {
                                SettingsValueRow(
                                    title: "Version",
                                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                                )
                                .contentShape(Rectangle())
                                .onTapGesture(count: 5) {
                                    showDebugTools.toggle()
                                }

                                Link(destination: URL(string: "https://nomva.nerdquad.com/privacy.html")!) {
                                    SettingsLinkRow(
                                        icon: "lock.doc",
                                        title: "Privacy Policy",
                                        subtitle: "How your data is handled"
                                    )
                                }
                                .buttonStyle(.plain)

//                                Link(destination: URL(string: "https://example.com/terms")!) {
//                                    SettingsLinkRow(
//                                        icon: "doc.text",
//                                        title: "Terms of Service",
//                                        subtitle: "Subscription and usage terms"
//                                    )
//                                }
//                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, contentInset)
                    .padding(.top, NomvaTheme.pageTopGap)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            dbMetadata = await DatabaseManager.shared.metadata()
            await garminManager.refreshIfNeeded()
        }
        .sheet(isPresented: $showPaywallPreview) {
            PaywallView()
        }
    }

    private var aiOverviewCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nomva Cloud")
                    .font(.title3.weight(.semibold))

                Text("AI features run through Nomva Cloud with GPT-4o-mini so food logging and edits stay consistent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: NomvaTheme.iconControlSize, height: NomvaTheme.iconControlSize)
                    .background(NomvaTheme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("GPT-4o-mini")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    private var membershipSubtitle: String {
        if isPremiumLocal {
            return showDebugTools
                ? "Developer override is currently enabled."
                : "Premium features are currently available on this build."
        }
        return "Restore your purchase on this device."
    }

    private var membershipStatus: String {
        if isPremiumLocal {
            return showDebugTools ? "Active" : "Available"
        }
        return "Restore"
    }

    private var garminSubtitle: String {
        if !garminManager.isConfigured {
            return "Nomva Cloud setup required"
        }
        if let average = garminManager.averageActiveCalories {
            return "Connected • \(Int(average.rounded())) active kcal/day avg"
        }
        if garminManager.isConnected {
            return "Connected • waiting for synced summaries"
        }
        if garminManager.isLoading {
            return "Checking connection…"
        }
        return "Connect Garmin to personalize goals"
    }
}

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    init(_ title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .nomvaCard(.standard, padding: NomvaTheme.standardCardPadding)
    }
}

private struct SettingsLinkRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(NomvaTheme.accent)
                .frame(width: NomvaTheme.iconControlSize, height: NomvaTheme.iconControlSize)
                .background(NomvaTheme.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsStatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct GarminSettingsDetailView: View {
    @EnvironmentObject private var garminManager: GarminManager
    @State private var showSuccess = false
    @State private var rotation: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Garmin Connect")
                        .font(.system(size: 34, weight: .bold, design: .rounded))

                    Text("Connect Garmin so Nomva Cloud can receive your daily activity summaries and feed them back into your calorie goals.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SettingsSectionCard("Connection", detail: "Garmin sign-in happens in a secure browser session and returns to Nomva when it finishes.") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(garminManager.isConnected ? "Connected" : "Not Connected")
                                    .font(.headline)
                                Text(connectionSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            NomvaTag(
                                text: garminManager.isConnected ? "Live" : garminManager.isConfigured ? "Ready" : "Setup",
                                tint: garminManager.isConnected ? .green : NomvaTheme.accent
                            )
                        }

                        if let average = garminManager.averageActiveCalories {
                            HStack(spacing: 12) {
                                SettingsStatTile(
                                    title: "Avg Active",
                                    value: "\(Int(average.rounded())) kcal"
                                )
                                SettingsStatTile(
                                    title: "Sample Days",
                                    value: "\(garminManager.status.sampledDays)"
                                )
                            }
                        }

                        if let latest = garminManager.status.latestSummary {
                            HStack(spacing: 12) {
                                SettingsStatTile(
                                    title: "Latest Calories",
                                    value: "\(Int(latest.activeCalories.rounded()))"
                                )
                                SettingsStatTile(
                                    title: "Latest Steps",
                                    value: latest.steps.map { $0.formatted() } ?? "—"
                                )
                            }
                        }

                        HStack(spacing: 12) {
                            if garminManager.isConnected {
                                Button {
                                    Task {
                                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                            rotation = 360
                                        }
                                        await garminManager.refresh(forceSync: true)
                                        withAnimation {
                                            rotation = 0
                                            showSuccess = true
                                        }
                                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                                        withAnimation { showSuccess = false }
                                    }
                                } label: {
                                    HStack {
                                        if garminManager.isLoading {
                                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                                .rotationEffect(.degrees(rotation))
                                        } else if showSuccess {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        } else {
                                            Text("Refresh")
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(NomvaSecondaryButtonStyle())

                                Button("Disconnect") {
                                    Task { await garminManager.disconnect() }
                                }
                                .buttonStyle(NomvaSecondaryButtonStyle())
                            } else {
                                Button("Connect Garmin") {
                                    Task { await garminManager.connect() }
                                }
                                .buttonStyle(NomvaPrimaryButtonStyle())
                                .disabled(!garminManager.isConfigured || garminManager.isConnecting)
                            }
                        }

                        if garminManager.isConfigured, let lastError = garminManager.lastErrorMessage, !lastError.isEmpty {
                            Text(lastError)
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                        } else if showSuccess {
                            Text("✓ Activity data updated.")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }
                }

                SettingsSectionCard("How It Works", detail: "This is a cloud-to-cloud integration, so Garmin data routes through Nomva Cloud before the app reads it.") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsValueRow(title: "OAuth", value: "Garmin Connect in browser")
                        SettingsValueRow(title: "Sync", value: "Daily summary webhook")
                        SettingsValueRow(title: "Used For", value: "Calorie goal personalization")
                    }
                }
            }
            .padding(.horizontal, NomvaTheme.contentInset)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(NomvaScreenBackground())
        .navigationTitle("Garmin")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await garminManager.refreshIfNeeded()
        }
    }

    private var connectionSubtitle: String {
        if !garminManager.isConfigured {
            return "Nomva Cloud still needs Garmin credentials and webhook configuration."
        }
        if let lastWebhook = garminManager.status.lastWebhookAt {
            return "Last sync: \(formattedTimestamp(lastWebhook))"
        }
        if garminManager.isConnected {
            return "Connected and waiting for your latest Garmin daily summaries."
        }
        return "Connect Garmin to let activity personalize your calorie goals."
    }

    private func formattedTimestamp(_ isoString: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // Try with fractional seconds first, then without
        var date = parser.date(from: isoString)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: isoString)
        }
        
        guard let date = date else { return isoString }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        displayFormatter.timeZone = .current // Explicitly use local time
        
        return displayFormatter.string(from: date)
    }
}

// MARK: - Custom Foods List

struct CustomFoodsListView: View {
    @Query(sort: \CustomFood.createdAt, order: .reverse) private var customFoods: [CustomFood]
    @Environment(\.modelContext) private var modelContext
    @State private var showCreateSheet = false

    var body: some View {
        List {
            ForEach(customFoods) { food in
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.name).font(.headline)
                    if let brand = food.brand {
                        Text(brand).font(.caption).foregroundColor(.secondary)
                    }
                    Text("\(Int(food.calories)) cal per \(food.servingDesc)")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .onDelete { indexSet in
                indexSet.forEach { modelContext.delete(customFoods[$0]) }
            }
        }
        .navigationTitle("Custom Foods")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add") { showCreateSheet = true }
                    .accessibilityLabel("Add custom food")
            }
            ToolbarItem(placement: .secondaryAction) {
                EditButton()
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            NavigationStack {
                CustomFoodCreateView()
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(GarminManager.shared)
}
