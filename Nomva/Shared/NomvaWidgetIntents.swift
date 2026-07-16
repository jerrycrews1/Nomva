import AppIntents
import Foundation

struct AddWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Water"
    static let description = IntentDescription("Log a quick water entry without opening Nomva.")
    static let openAppWhenRun = false

    @Parameter(title: "Amount (oz)")
    var amountOz: Double

    init() {
        self.amountOz = 8
    }

    init(amountOz: Double) {
        self.amountOz = amountOz
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sanitizedAmount = max(1, amountOz.rounded())
        NomvaPendingHydrationStore.enqueue(amountOz: sanitizedAmount)
        NomvaWidgetSnapshotStore.incrementHydration(by: sanitizedAmount)
        return .result(dialog: IntentDialog("Logged \(Int(sanitizedAmount)) oz of water."))
    }
}

private protocol NomvaOpenIntent: AppIntent {
    static var destination: NomvaWidgetRoute { get }
}

extension NomvaOpenIntent {
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        NomvaWidgetRouteStore.save(Self.destination)
        return .result()
    }
}

struct OpenTodayLogIntent: NomvaOpenIntent {
    static let title: LocalizedStringResource = "Open Today's Log"
    static let description = IntentDescription("Open Nomva to today's food log.")
    static let destination: NomvaWidgetRoute = .todayLog
}

struct OpenChatIntent: NomvaOpenIntent {
    static let title: LocalizedStringResource = "Open AI Chat"
    static let description = IntentDescription("Open Nomva's AI chat food logger.")
    static let destination: NomvaWidgetRoute = .chat
}

struct OpenManualSearchIntent: NomvaOpenIntent {
    static let title: LocalizedStringResource = "Add Food"
    static let description = IntentDescription("Open Nomva directly to the add food flow.")
    static let destination: NomvaWidgetRoute = .manualSearch
}

struct OpenBarcodeIntent: NomvaOpenIntent {
    static let title: LocalizedStringResource = "Scan Barcode"
    static let description = IntentDescription("Open Nomva's barcode scanner.")
    static let destination: NomvaWidgetRoute = .barcode
}

struct OpenWeightLogIntent: NomvaOpenIntent {
    static let title: LocalizedStringResource = "Log Weight"
    static let description = IntentDescription("Open Nomva to the weight logging flow.")
    static let destination: NomvaWidgetRoute = .weightLog
}

struct OpenGoalsIntent: NomvaOpenIntent {
    static let title: LocalizedStringResource = "Open Goals"
    static let description = IntentDescription("Open Nomva's goal and activity settings.")
    static let destination: NomvaWidgetRoute = .goals
}
