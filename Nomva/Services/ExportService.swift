import Foundation
import SwiftData

@MainActor
final class ExportService {
    static let shared = ExportService()

    enum DetailLevel {
        case summary, detailed
    }

    func generateCoachReport(
        entries: [FoodEntry],
        weights: [WeightEntry],
        water: [WaterEntry],
        goals: [DailyGoal],
        detailLevel: DetailLevel = .detailed
    ) -> URL? {
        let currentGoal = GoalService.currentGoal(from: goals)
        let calendar = Calendar.current
        let allDates = Set(
            entries.map { calendar.startOfDay(for: $0.date) }
                + weights.map { calendar.startOfDay(for: $0.date) }
                + water.map { calendar.startOfDay(for: $0.date) }
        )
        .sorted(by: >)

        var rows: [[String]] = []
        if detailLevel == .summary {
            rows.append([
                "Date", "Calories", "Protein (g)", "Carbs (g)", "Fat (g)",
                "Fiber (g)", "Water (oz)", "Weight (lb)", "Calorie Goal",
                "Protein Goal (g)", "Carb Goal (g)", "Fat Goal (g)"
            ])
        } else {
            rows.append([
                "Date", "Meal", "Food", "Brand", "Portion", "Servings",
                "Serving Unit", "Calories", "Protein (g)", "Carbs (g)",
                "Fat (g)", "Fiber (g)", "Water (oz)", "Weight (lb)",
                "Source", "FDC ID", "Database ID", "Barcode", "Original Input"
            ])
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for date in allDates {
            let dayEntries = entries.filter { calendar.isDate($0.date, inSameDayAs: date) }
            let dayWater = water
                .filter { calendar.isDate($0.date, inSameDayAs: date) }
                .reduce(0) { $0 + $1.amountOz }
            let dayWeight = weights
                .filter { calendar.isDate($0.date, inSameDayAs: date) }
                .sorted { $0.date > $1.date }
                .first?.weightLbs

            if detailLevel == .summary {
                let totals = NutritionTotals.from(entries: dayEntries)
                rows.append([
                    formatter.string(from: date),
                    number(totals.calories),
                    number(totals.protein),
                    number(totals.carbs),
                    number(totals.fat),
                    number(totals.fiber),
                    number(dayWater),
                    dayWeight.map(number) ?? "",
                    number(currentGoal.calories),
                    number(currentGoal.protein),
                    number(currentGoal.carbs),
                    number(currentGoal.fat)
                ])
                continue
            }

            if dayEntries.isEmpty {
                rows.append([
                    formatter.string(from: date), "", "", "", "", "", "", "",
                    "", "", "", "", number(dayWater), dayWeight.map(number) ?? "",
                    "", "", "", "", ""
                ])
            } else {
                for entry in dayEntries.sorted(by: { $0.date < $1.date }) {
                    rows.append([
                        formatter.string(from: date),
                        MealCategory(storedValue: entry.meal).title,
                        entry.name,
                        entry.brand ?? "",
                        entry.portionDescription,
                        number(entry.servings),
                        entry.servingUnit,
                        number(entry.calories),
                        number(entry.proteinG),
                        number(entry.carbsG),
                        number(entry.fatG),
                        number(entry.fiberG),
                        number(dayWater),
                        dayWeight.map(number) ?? "",
                        entry.source ?? "",
                        entry.fdcId.map(String.init) ?? "",
                        entry.foodDatabaseId.map(String.init) ?? "",
                        entry.barcode ?? "",
                        entry.rawUserInput
                    ])
                }
            }
        }

        let csv = rows
            .map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
        let url = URL.documentsDirectory.appending(path: "Nomva_Coach_Report.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    struct BackupData: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let archive: SyncMigrationService.Archive?

        // Version 1 compatibility. New backups use archive.
        let foods: [FoodBackup]
        let weights: [WeightBackup]
        let goals: [GoalBackup]
        let water: [WaterBackup]

        init(archive: SyncMigrationService.Archive) {
            schemaVersion = 2
            exportedAt = archive.exportedAt
            self.archive = archive
            foods = []
            weights = []
            goals = []
            water = []
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, exportedAt, archive, foods, weights, goals, water
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? .distantPast
            archive = try container.decodeIfPresent(SyncMigrationService.Archive.self, forKey: .archive)
            foods = try container.decodeIfPresent([FoodBackup].self, forKey: .foods) ?? []
            weights = try container.decodeIfPresent([WeightBackup].self, forKey: .weights) ?? []
            goals = try container.decodeIfPresent([GoalBackup].self, forKey: .goals) ?? []
            water = try container.decodeIfPresent([WaterBackup].self, forKey: .water) ?? []
        }
    }

    func generateBackup() -> URL? {
        do {
            let manager = ModelContainerManager.shared
            let archive = try SyncMigrationService.captureArchive(
                from: manager.container,
                storeKind: manager.activeStoreKind
            )
            let backup = BackupData(archive: archive)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(backup)
            let url = URL.documentsDirectory.appending(path: "Nomva_Backup.json")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - Legacy Version 1 Backup Models

struct FoodBackup: Codable {
    let name: String
    let brand: String?
    let meal: String
    let date: Date
    let grams: Double
    let desc: String
    let servings: Double
    let unit: String
    let cals: Double
    let p: Double
    let c: Double
    let f: Double
    let fiber: Double
}

struct WeightBackup: Codable {
    let date: Date
    let lbs: Double
    let note: String?
}

struct GoalBackup: Codable {
    let cal: Double
    let p: Double
    let c: Double
    let f: Double
}

struct WaterBackup: Codable {
    let date: Date
    let oz: Double
}
