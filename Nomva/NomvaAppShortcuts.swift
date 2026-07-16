import AppIntents

struct NomvaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTodayLogIntent(),
            phrases: [
                "Open today's log in \(.applicationName)",
                "Show my food log in \(.applicationName)"
            ],
            shortTitle: "Today's Log",
            systemImageName: "list.bullet.clipboard"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open AI chat in \(.applicationName)",
                "Log food with chat in \(.applicationName)"
            ],
            shortTitle: "AI Chat",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenManualSearchIntent(),
            phrases: [
                "Add food in \(.applicationName)",
                "Search food in \(.applicationName)"
            ],
            shortTitle: "Add Food",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenBarcodeIntent(),
            phrases: [
                "Scan a barcode in \(.applicationName)",
                "Open barcode scanner in \(.applicationName)"
            ],
            shortTitle: "Scan Barcode",
            systemImageName: "barcode.viewfinder"
        )
        AppShortcut(
            intent: OpenWeightLogIntent(),
            phrases: [
                "Log weight in \(.applicationName)",
                "Open weight log in \(.applicationName)"
            ],
            shortTitle: "Log Weight",
            systemImageName: "scalemass"
        )
        AppShortcut(
            intent: AddWaterIntent(amountOz: 8),
            phrases: [
                "Add water in \(.applicationName)",
                "Log hydration in \(.applicationName)"
            ],
            shortTitle: "Add Water",
            systemImageName: "drop.fill"
        )
    }
}
