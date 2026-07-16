import Foundation
import WidgetKit

enum NomvaWidgetSnapshotStore {
    private static let snapshotKey = "widget.snapshot.v1"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func readSnapshot() -> NomvaWidgetSnapshot {
        guard let data = NomvaWidgetSuite.defaults.data(forKey: snapshotKey),
              let snapshot = try? decoder.decode(NomvaWidgetSnapshot.self, from: data) else {
            return .placeholder
        }
        return snapshot
    }

    static func writeSnapshot(_ snapshot: NomvaWidgetSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        NomvaWidgetSuite.defaults.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func updateSnapshot(_ update: (inout NomvaWidgetSnapshot) -> Void) {
        var snapshot = readSnapshot()
        update(&snapshot)
        writeSnapshot(snapshot)
    }

    static func incrementHydration(by amountOz: Double, at date: Date = .now) {
        updateSnapshot { snapshot in
            snapshot.hydration.totalOz += amountOz
            snapshot.lastUpdatedAt = date
        }
    }
}
