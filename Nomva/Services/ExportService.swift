import Foundation
import SwiftData

@MainActor
final class ExportService {
    static let shared = ExportService()
    
    // MARK: - Fitness Coach Report (CSV)
    
    enum DetailLevel {
        case summary, detailed
    }
    
    func generateCoachReport(entries: [FoodEntry], weights: [WeightEntry], detailLevel: DetailLevel = .detailed) -> URL? {
        var csv: String
        if detailLevel == .summary {
            csv = "Date,Calories,Protein(g),Carbs(g),Fat(g),Weight(lbs)\n"
        } else {
            csv = "Date,Meal,Food,Brand,Portion,Calories,Protein(g),Carbs(g),Fat(g),Weight(lbs)\n"
        }
        
        let allDates = Set(entries.map { Calendar.current.startOfDay(for: $0.date) } + 
                          weights.map { Calendar.current.startOfDay(for: $0.date) }).sorted(by: >)
        
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        
        for date in allDates {
            let dayEntries = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
            let dayWeight = weights.first { Calendar.current.isDate($0.date, inSameDayAs: date) }?.weightLbs ?? 0
            
            if detailLevel == .summary {
                let totals = dayEntries.reduce(into: (cal: 0.0, p: 0.0, c: 0.0, f: 0.0)) { res, e in
                    res.cal += e.calories; res.p += e.proteinG; res.c += e.carbsG; res.f += e.fatG
                }
                let row = [
                    df.string(from: date),
                    "\(Int(totals.cal))",
                    "\(Int(totals.p))",
                    "\(Int(totals.c))",
                    "\(Int(totals.f))",
                    dayWeight > 0 ? String(format: "%.1f", dayWeight) : ""
                ].joined(separator: ",")
                csv += row + "\n"
            } else {
                if dayEntries.isEmpty && dayWeight > 0 {
                    csv += "\(df.string(from: date)),,,,,\(String(format: "%.1f", dayWeight))\n"
                }
                
                for e in dayEntries {
                    let row = [
                        df.string(from: date),
                        e.meal,
                        e.name.replacingOccurrences(of: ",", with: ""),
                        (e.brand ?? "").replacingOccurrences(of: ",", with: ""),
                        e.portionDescription.replacingOccurrences(of: ",", with: ""),
                        "\(Int(e.calories))",
                        "\(Int(e.proteinG))",
                        "\(Int(e.carbsG))",
                        "\(Int(e.fatG))",
                        dayWeight > 0 ? String(format: "%.1f", dayWeight) : ""
                    ].joined(separator: ",")
                    csv += row + "\n"
                }
            }
        }
        
        let url = URL.documentsDirectory.appending(path: "Nomva_Coach_Report.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    // MARK: - App Backup (JSON)
    
    struct BackupData: Codable {
        let foods: [FoodBackup]
        let weights: [WeightBackup]
        let goals: [GoalBackup]
        let water: [WaterBackup]
    }
    
    func generateBackup(foods: [FoodEntry], weights: [WeightEntry], goals: [DailyGoal], water: [WaterEntry]) -> URL? {
        let backup = BackupData(
            foods: foods.map { FoodBackup(from: $0) },
            weights: weights.map { WeightBackup(from: $0) },
            goals: goals.map { GoalBackup(from: $0) },
            water: water.map { WaterBackup(from: $0) }
        )
        
        guard let data = try? JSONEncoder().encode(backup) else { return nil }
        let url = URL.documentsDirectory.appending(path: "Nomva_Backup.json")
        try? data.write(to: url)
        return url
    }
}

// MARK: - Backup Models (Simplified Codable versions of SwiftData classes)

struct FoodBackup: Codable {
    let name: String; let brand: String?; let meal: String; let date: Date
    let grams: Double; let desc: String; let servings: Double; let unit: String
    let cals: Double; let p: Double; let c: Double; let f: Double; let fiber: Double
    
    init(from e: FoodEntry) {
        self.name = e.name; self.brand = e.brand; self.meal = e.meal; self.date = e.date
        self.grams = e.portionGrams; self.desc = e.portionDescription; self.servings = e.servings; self.unit = e.servingUnit
        self.cals = e.calories; self.p = e.proteinG; self.c = e.carbsG; self.f = e.fatG; self.fiber = e.fiberG
    }
}

struct WeightBackup: Codable {
    let date: Date; let lbs: Double; let note: String?
    init(from w: WeightEntry) { self.date = w.date; self.lbs = w.weightLbs; self.note = w.note }
}

struct GoalBackup: Codable {
    let cal: Double; let p: Double; let c: Double; let f: Double
    init(from g: DailyGoal) { self.cal = g.calories; self.p = g.protein; self.c = g.carbs; self.f = g.fat }
}

struct WaterBackup: Codable {
    let date: Date; let oz: Double
    init(from h: WaterEntry) { self.date = h.date; self.oz = h.amountOz }
}
