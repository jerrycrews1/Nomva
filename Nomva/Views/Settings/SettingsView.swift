import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var garminManager: GarminManager
    @EnvironmentObject private var syncManager: SyncManager
    @EnvironmentObject private var routeCenter: NomvaRouteCenter
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var dbMetadata: (totalFoods: Int, buildDate: String) = (0, "Unknown")
    @State private var showPaywallPreview = false
    @State private var showGoalsFromWidget = false
    #if targetEnvironment(simulator)
    @State private var showSeedScreenshotDataConfirm = false
    @State private var simulatorSeedMessage: String?
    @State private var isSeedingSimulatorData = false
    #endif

    private let contentInset: CGFloat = NomvaTheme.contentInset

    var body: some View {
        NavigationStack {
            ZStack {
                NomvaScreenBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: NomvaTheme.sectionGap) {
                        NavigationLink {
                            LLMProviderSettingsView()
                        } label: {
                            aiOverviewCard
                        }
                        .buttonStyle(.plain)

                        SettingsSectionCard("Nutrition", detail: "Review targets, formulas, and connected activity data.") {
                            NavigationLink {
                                GoalsSettingsView()
                            } label: {
                                SettingsLinkRow(
                                    icon: "target",
                                    title: "Calorie & Macro Goals",
                                    subtitle: "Targets, formulas, and activity basis"
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        SettingsSectionCard("Integrations", detail: "Connect activity sources that can adjust your calorie target.") {
                            VStack(spacing: 12) {
                                NavigationLink {
                                    AppleHealthSettingsDetailView()
                                } label: {
                                    SettingsLinkRow(
                                        icon: "heart.fill",
                                        title: "Apple Health",
                                        subtitle: appleHealthSubtitle
                                    )
                                }
                                .buttonStyle(.plain)

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
                        }

                        SettingsSectionCard("Data", detail: "Manage sync and your custom food library.") {
                            VStack(spacing: 12) {
                                NavigationLink {
                                    iCloudSyncSettingsView()
                                } label: {
                                    SettingsLinkRow(
                                        icon: "icloud",
                                        title: "iCloud Sync",
                                        subtitle: iCloudSubtitle
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

                        SettingsSectionCard("Membership", detail: "Check your plan or restore purchases.") {
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
                                        tint: subscriptionManager.isPremium ? NomvaTheme.success : NomvaTheme.accent
                                    )
                                }

                                if subscriptionManager.hasTestFlightAccess {
                                    Label(
                                        "Pro is unlocked for this TestFlight build.",
                                        systemImage: "checkmark.seal.fill"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(NomvaTheme.success)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
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

                                if let message = subscriptionManager.purchaseState.feedbackMessage,
                                   !subscriptionManager.hasTestFlightAccess {
                                    Text(message)
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(
                                            subscriptionManager.purchaseState.isError ? NomvaTheme.danger : Color.secondary
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        SettingsSectionCard("Backup & Export", detail: "Export your data or save a backup.") {
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

                        SettingsSectionCard("Food Database", detail: "Info about the nutrition database included with the app.") {
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

                        SettingsSectionCard("About", detail: "Legal links and app info.") {
                            VStack(spacing: 12) {
                                SettingsValueRow(
                                    title: "Version",
                                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                                )

                                Link(destination: URL(string: "https://nomva.nerdquad.com/privacy.html")!) {
                                    SettingsLinkRow(
                                        icon: "lock.doc",
                                        title: "Privacy Policy",
                                        subtitle: "How your data is handled"
                                    )
                                }
                                .buttonStyle(.plain)

                                Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                                    SettingsLinkRow(
                                        icon: "doc.text",
                                        title: "Terms of Use",
                                        subtitle: "Apple standard app license"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        #if targetEnvironment(simulator)
                        SettingsSectionCard("Simulator Tools", detail: "Reset the simulator to a fixed sample state for screenshots and previews.") {
                            VStack(alignment: .leading, spacing: 14) {
                                Button {
                                    showSeedScreenshotDataConfirm = true
                                } label: {
                                    HStack {
                                        if isSeedingSimulatorData {
                                            ProgressView()
                                                .tint(NomvaTheme.onAccent)
                                        } else {
                                            Image(systemName: "photo.on.rectangle.angled")
                                                .font(.headline.weight(.semibold))
                                        }

                                        Text(isSeedingSimulatorData ? "Seeding Screenshot Data..." : "Seed Screenshot Data")
                                            .font(.headline)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(NomvaPrimaryButtonStyle())
                                .disabled(isSeedingSimulatorData)

                                Text("This replaces the simulator's local app data with repeatable meals, chat, hydration, goals, and weight history.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let simulatorSeedMessage {
                                    Text(simulatorSeedMessage)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        #endif
                    }
                    .padding(.horizontal, contentInset)
                    .padding(.top, NomvaTheme.pageTopGap)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showGoalsFromWidget) {
                GoalsSettingsView()
            }
        }
        .task {
            dbMetadata = await DatabaseManager.shared.metadata()
            await garminManager.refreshIfNeeded()
        }
        .onReceive(routeCenter.$currentRoute.compactMap { $0 }) { route in
            guard route == .goals else { return }
            showGoalsFromWidget = true
            routeCenter.clear(route)
        }
        .sheet(isPresented: $showPaywallPreview) {
            PaywallView()
        }
        #if targetEnvironment(simulator)
        .alert("Replace simulator data?", isPresented: $showSeedScreenshotDataConfirm) {
            Button("Seed Screenshot Data", role: .destructive) {
                seedScreenshotData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets the simulator's local app data to a repeatable sample state for screenshots.")
        }
        #endif
    }

    private var aiOverviewCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nomva Cloud")
                    .font(.title3.weight(.semibold))

                Text("Some AI features run through Nomva Cloud with task-specific GPT-5 models. These tools need an internet connection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(NomvaTheme.onAccent)
                    .frame(width: NomvaTheme.iconControlSize, height: NomvaTheme.iconControlSize)
                    .background(NomvaTheme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("GPT-5")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .nomvaCard(.hero, padding: NomvaTheme.heroCardPadding)
    }

    private var membershipSubtitle: String {
        if subscriptionManager.hasTestFlightAccess {
            return "All Pro features are unlocked for beta testing."
        }
        if subscriptionManager.isPremium {
            return "Pro features are active on this device."
        }
        return "Restore a purchase on this device."
    }

    private var membershipStatus: String {
        if subscriptionManager.hasTestFlightAccess {
            return "TestFlight"
        }
        if subscriptionManager.isPremium {
            return "Active"
        }
        return "Restore"
    }

    private var iCloudSubtitle: String {
        if syncManager.iCloudEnabled {
            return "Active in your private iCloud"
        }
        if let error = syncManager.lastErrorMessage, !error.isEmpty {
            return "Local only • issue needs attention"
        }
        if syncManager.isAccountAvailable {
            return "On-device only"
        }
        return "Local only • iCloud unavailable"
    }

    @AppStorage("goal_activity_source") private var activitySourceRaw = GoalActivitySource.manual.rawValue

    private var appleHealthSubtitle: String {
        guard AppleHealthService.isAvailable() else {
            return "Not available on this device"
        }
        if activitySourceRaw == GoalActivitySource.appleHealth.rawValue {
            return "Active — adjusting your calorie goals"
        }
        return "Available — tap to connect"
    }

    private var garminSubtitle: String {
        if !garminManager.isConfigured {
            return "Nomva Cloud setup required"
        }
        if let average = garminManager.averageActiveCalories {
            return "Connected • \(average.safeRoundedInt) active kcal/day avg"
        }
        if garminManager.isConnected {
            return "Connected • waiting for synced summaries"
        }
        if garminManager.isLoading {
            return "Checking connection…"
        }
        return "Connect Garmin to personalize goals"
    }

    #if targetEnvironment(simulator)
    private func seedScreenshotData() {
        isSeedingSimulatorData = true
        simulatorSeedMessage = nil

        do {
            try SeedData.seedAppStoreData(context: modelContext)
            simulatorSeedMessage = "Screenshot data loaded. You can capture the same polished sample state anytime."
        } catch {
            simulatorSeedMessage = "Couldn't seed screenshot data: \(error.localizedDescription)"
        }

        isSeedingSimulatorData = false
    }
    #endif
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

                    Text("Use your Garmin activity data to automatically adjust your daily calorie goals.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SettingsSectionCard("Connection", detail: "You'll sign in to Garmin through a secure browser. Nomva only reads your daily active calories.") {
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
                                tint: garminManager.isConnected ? NomvaTheme.success : NomvaTheme.accent
                            )
                        }

                        if let average = garminManager.averageActiveCalories {
                            HStack(spacing: 12) {
                                SettingsStatTile(
                                    title: "Avg Active",
                                    value: "\(average.safeRoundedInt) kcal"
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
                                    value: "\(latest.activeCalories.safeRoundedInt)"
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
                                                .foregroundStyle(NomvaTheme.success)
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
                                .foregroundStyle(NomvaTheme.danger)
                        } else if showSuccess {
                            Text("✓ Activity data updated.")
                                .font(.caption.bold())
                                .foregroundStyle(NomvaTheme.success)
                        }
                    }
                }

                SettingsSectionCard("How It Works", detail: "Garmin syncs through Nomva Cloud so the app can receive your daily summaries.") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsValueRow(title: "Data Read", value: "Daily active calories")
                        SettingsValueRow(title: "Syncs", value: "Automatically each day")
                        SettingsValueRow(title: "Used For", value: "Calorie goal adjustment")
                        SettingsValueRow(title: "Privacy", value: "No data sold or shared")
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
            return "Garmin integration isn't set up yet."
        }
        if let lastWebhook = garminManager.status.lastWebhookAt {
            return "Last synced: \(formattedTimestamp(lastWebhook))"
        }
        if garminManager.isConnected {
            return "Connected — waiting for today's activity data."
        }
        return "Tap Connect to link your Garmin account."
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

// MARK: - Apple Health Settings Detail

private struct AppleHealthSettingsDetailView: View {
    @AppStorage("goal_activity_source") private var activitySourceRaw = GoalActivitySource.manual.rawValue
    @State private var summary: AppleHealthActivitySummary?
    @State private var isLoading = true
    @State private var isConnected = false
    @State private var errorMessage: String?
    @State private var showSuccess = false

    private var isActive: Bool {
        activitySourceRaw == GoalActivitySource.appleHealth.rawValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apple Health")
                        .font(.system(size: 34, weight: .bold, design: .rounded))

                    Text("Use your actual activity data to automatically adjust your daily calorie goals.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SettingsSectionCard("Connection", detail: "Nomva reads your active calories on-device. Nothing is sent to any server.") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(connectionTitle)
                                    .font(.headline)
                                Text(connectionSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            NomvaTag(
                                text: isActive ? "Active" : isConnected ? "Connected" : "Off",
                                tint: isActive ? NomvaTheme.success : isConnected ? NomvaTheme.info : NomvaTheme.accent
                            )
                        }

                        if let summary {
                            HStack(spacing: 12) {
                                SettingsStatTile(
                                    title: "Avg Active",
                                    value: "\(summary.averageActiveCalories.safeRoundedInt) kcal"
                                )
                                SettingsStatTile(
                                    title: "Sample Days",
                                    value: "\(summary.sampledDays) of \(summary.windowDays)"
                                )
                            }
                        }

                        if isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Checking Apple Health…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else if !AppleHealthService.isAvailable() {
                            Text("Apple Health is not available on this device.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if !isConnected {
                            Button("Connect Apple Health") {
                                Task { await connectAppleHealth() }
                            }
                            .buttonStyle(NomvaPrimaryButtonStyle())
                        } else {
                            HStack(spacing: 12) {
                                Button(isActive ? "Active Source ✓" : "Set as Activity Source") {
                                    withAnimation {
                                        activitySourceRaw = GoalActivitySource.appleHealth.rawValue
                                    }
                                }
                                .modifier(ActivitySourceButtonStyleModifier(isActive: isActive))
                                .disabled(isActive || summary == nil)

                                Button("Refresh") {
                                    Task { await refreshData() }
                                }
                                .buttonStyle(NomvaSecondaryButtonStyle())
                            }

                            if isActive {
                                Text("Apple Health is adjusting your calorie goals.")
                                    .font(.caption)
                                    .foregroundStyle(NomvaTheme.success)
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption.bold())
                                .foregroundStyle(NomvaTheme.danger)
                        }

                        if showSuccess {
                            Text("✓ Activity data refreshed.")
                                .font(.caption.bold())
                                .foregroundStyle(NomvaTheme.success)
                        }
                    }
                }

                SettingsSectionCard("How It Works", detail: "All data stays on your device — nothing is sent to Nomva's servers.") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsValueRow(title: "Data Read", value: "Daily active calories")
                        SettingsValueRow(title: "Window", value: "Last 28 days")
                        SettingsValueRow(title: "Used For", value: "Calorie goal adjustment")
                        SettingsValueRow(title: "Privacy", value: "On-device only, always")
                    }
                }
            }
            .padding(.horizontal, NomvaTheme.contentInset)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(NomvaScreenBackground())
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await checkStatus()
        }
    }

    private var connectionTitle: String {
        if !AppleHealthService.isAvailable() { return "Unavailable" }
        if isConnected { return isActive ? "Active Source" : "Connected" }
        return "Not Connected"
    }

    private var connectionSubtitle: String {
        if !AppleHealthService.isAvailable() {
            return "Apple Health is not available on this device."
        }
        if let summary {
            return "Avg \(summary.averageActiveCalories.safeRoundedInt) active kcal/day over \(summary.sampledDays) days"
        }
        if isConnected {
            return "Connected — waiting for activity data"
        }
        return "Tap Connect to get started."
    }

    private func checkStatus() async {
        isLoading = true
        defer { isLoading = false }

        guard AppleHealthService.isAvailable() else { return }

        do {
            let status = try await AppleHealthService.requestStatus()
            switch status {
            case .ready:
                isConnected = true
                await refreshData()
            case .shouldRequest:
                isConnected = false
            default:
                isConnected = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectAppleHealth() async {
        do {
            try await AppleHealthService.requestAuthorization()
            isConnected = true
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshData() async {
        do {
            summary = try await AppleHealthService.fetchAverageActiveCalories()
            withAnimation {
                showSuccess = true
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { showSuccess = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ActivitySourceButtonStyleModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.buttonStyle(NomvaSecondaryButtonStyle())
        } else {
            content.buttonStyle(NomvaPrimaryButtonStyle())
        }
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
                    Text("\(food.calories.safeRoundedInt) cal per \(food.servingDesc)")
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
        .environmentObject(NomvaRouteCenter.shared)
}
