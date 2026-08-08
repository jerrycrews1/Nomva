import SQLite3
import Foundation

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private let foodSelectColumns = """
    f.id, f.fdc_id, f.name, f.brand, f.source, f.serving_g, f.serving_desc,
    f.calories, f.protein_g, f.carbs_g, f.fat_g, f.fiber_g,
    f.sugar_g, f.sodium_mg,
    f.saturated_fat_g, f.trans_fat_g, f.cholesterol_mg, f.added_sugar_g,
    f.vitamin_d_mcg, f.calcium_mg, f.iron_mg, f.potassium_mg,
    f.vitamin_a_mcg_rae, f.vitamin_c_mg, f.vitamin_b12_mcg,
    f.folate_mcg_dfe, f.magnesium_mg, f.zinc_mg, f.barcode,
    f.portion_basis, f.serving_source
"""

actor DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?

    private init() {
        guard let dbPath = Bundle.main.path(forResource: "foods", ofType: "sqlite") else {
            print("DatabaseManager: foods.sqlite not found in bundle")
            return
        }
        var openedDatabase: OpaquePointer?
        // SQLITE_OPEN_NOFOLLOW avoids symlink attacks; SQLITE_OPEN_READONLY keeps it safe
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        if sqlite3_open_v2(dbPath, &openedDatabase, flags, nil) != SQLITE_OK {
            print("DatabaseManager: failed to open database")
            if let openedDatabase { sqlite3_close(openedDatabase) }
            return
        }
        db = openedDatabase

        // Performance tuning — dramatically reduces cold-open time on device
        // mmap: let the OS handle paging instead of read() calls
        // cache_size: keep more pages in memory (negative = KB)
        // temp_store: keep temp tables in memory
        let pragmas = [
            "PRAGMA mmap_size=134217728",   // 128 MB memory-mapped I/O
            "PRAGMA cache_size=-8000",       // 8 MB page cache
            "PRAGMA temp_store=MEMORY",
            "PRAGMA journal_mode=OFF",       // read-only db, no WAL needed
        ]
        for pragma in pragmas {
            sqlite3_exec(db, pragma, nil, nil, nil)
        }
    }

    private func normalizedBarcode(_ barcode: String) -> String? {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        let trimmed = String(digits.drop(while: { $0 == "0" }))
        return trimmed.isEmpty ? "0" : trimmed
    }

    // MARK: - Search

    /// Natural language fuzzy search using FTS5
    func search(query: String, limit: Int = 25) -> [FoodItem] {
        guard let db = db else { return [] }

        let matchQuery = buildMatchQuery(from: query)
        guard !matchQuery.isEmpty else { return [] }
        
        let lowerQuery = query.lowercased()

        let sql = """
            SELECT \(foodSelectColumns)
            FROM foods f
            JOIN foods_fts ON foods_fts.rowid = f.id
            WHERE foods_fts MATCH ?
            ORDER BY
                CASE
                    WHEN f.source = 'foundation' THEN 0
                    WHEN f.source = 'survey_fndds' THEN 1
                    WHEN f.source = 'sr_legacy' THEN 2
                    ELSE 3
                END ASC,
                CASE WHEN lower(f.name) = ? THEN 0 ELSE 1 END ASC,
                CASE WHEN lower(f.name) LIKE ? THEN 0 ELSE 1 END ASC,
                CASE WHEN lower(f.name) LIKE ? THEN 0 ELSE 1 END ASC,
                rank ASC,
                LENGTH(f.name) ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        var results: [FoodItem] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, matchQuery, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, lowerQuery, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, "\(lowerQuery)%", -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, "%\(lowerQuery)%", -1, sqliteTransient)
            sqlite3_bind_int(stmt, 5, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FoodItem(from: stmt!))
            }
        }

        sqlite3_finalize(stmt)
        return results
    }

    /// Broader fallback search that prefers generic matches when FTS is too noisy.
    func searchLoose(query: String, limit: Int = 25) -> [FoodItem] {
        guard let db = db else { return [] }

        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return [] }

        let whereClause = tokens.map { _ in
            "(lower(f.name) LIKE ? OR lower(IFNULL(f.brand, '')) LIKE ? OR lower(IFNULL(f.search_terms, '')) LIKE ?)"
        }
            .joined(separator: " AND ")

        let sql = """
            SELECT \(foodSelectColumns)
            FROM foods f
            WHERE \(whereClause)
            ORDER BY
                CASE
                    WHEN f.source = 'foundation' THEN 0
                    WHEN f.source = 'survey_fndds' THEN 1
                    WHEN f.source = 'sr_legacy' THEN 2
                    WHEN f.source = 'branded' THEN 3
                    ELSE 4
                END ASC,
                CASE WHEN f.brand IS NULL OR f.brand = '' THEN 0 ELSE 1 END ASC,
                LENGTH(f.name) ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        var results: [FoodItem] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            for token in tokens {
                let like = "%\(token)%"
                sqlite3_bind_text(stmt, bindIndex, like, -1, sqliteTransient)
                bindIndex += 1
                sqlite3_bind_text(stmt, bindIndex, like, -1, sqliteTransient)
                bindIndex += 1
                sqlite3_bind_text(stmt, bindIndex, like, -1, sqliteTransient)
                bindIndex += 1
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FoodItem(from: stmt!))
            }
        }

        sqlite3_finalize(stmt)
        return results
    }

    private func buildMatchQuery(from query: String) -> String {
        let normalized = query
            .lowercased()
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "\"", with: " ")

        let tokens = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }

        if tokens.count == 1 {
            return "\(tokens[0])*"
        }

        let phrase = tokens.joined(separator: " ")
        let allTerms = tokens.map { "\($0)*" }.joined(separator: " AND ")
        return "\"\(phrase)\" OR \(allTerms)"
    }

    /// Direct lookup by FDC ID
    func food(byFdcId fdcId: Int) -> FoodItem? {
        guard let db = db else { return nil }

        let sql = """
            SELECT \(foodSelectColumns)
            FROM foods f WHERE f.fdc_id = ?
        """

        var stmt: OpaquePointer?
        var result: FoodItem?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(fdcId))
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = FoodItem(from: stmt!)
            }
        }

        sqlite3_finalize(stmt)
        return result
    }

    /// Direct lookup by local row ID
    func food(byRowId rowId: Int) -> FoodItem? {
        guard let db = db else { return nil }

        let sql = """
            SELECT \(foodSelectColumns)
            FROM foods f WHERE f.id = ?
        """

        var stmt: OpaquePointer?
        var result: FoodItem?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(rowId))
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = FoodItem(from: stmt!)
            }
        }

        sqlite3_finalize(stmt)
        return result
    }

    /// Direct lookup by barcode (GTIN/UPC)
    func food(byBarcode barcode: String) -> FoodItem? {
        guard let db = db else { return nil }

        let rawBarcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBarcode.isEmpty else { return nil }

        let normalizedBarcode = normalizedBarcode(rawBarcode) ?? rawBarcode
        let sql = """
            SELECT \(foodSelectColumns)
            FROM foods f
            WHERE f.barcode = ?
               OR f.barcode = ?
               OR ltrim(replace(replace(IFNULL(f.barcode, ''), ' ', ''), '-', ''), '0') = ?
            ORDER BY
                CASE WHEN f.source = 'open_food_facts' THEN 1 ELSE 0 END ASC,
                CASE WHEN f.barcode = ? THEN 0 ELSE 1 END ASC
            LIMIT 1
        """

        var stmt: OpaquePointer?
        var result: FoodItem?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, rawBarcode, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, normalizedBarcode, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, normalizedBarcode, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, rawBarcode, -1, sqliteTransient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = FoodItem(from: stmt!)
            }
        }

        sqlite3_finalize(stmt)
        return result
    }

    /// Get DB metadata (food count, build date) for display in Settings
    func metadata() -> (totalFoods: Int, buildDate: String) {
        guard let db = db else { return (0, "Unknown") }

        var total = 0
        var buildDate = "Unknown"

        let sql = "SELECT key, value FROM metadata"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let value = String(cString: sqlite3_column_text(stmt, 1))
                if key == "total_foods" { total = Int(value) ?? 0 }
                if key == "build_date" { buildDate = value }
            }
        }

        sqlite3_finalize(stmt)
        return (total, buildDate)
    }
}

enum BarcodeLookupSource {
    case bundledDatabase
}

enum BarcodeLookupOutcome {
    case found(FoodItem, BarcodeLookupSource)
    case notFound
    case unavailable
}

actor BarcodeLookupService {
    static let shared = BarcodeLookupService()

    private let database = DatabaseManager.shared

    func lookup(barcode: String) async -> BarcodeLookupOutcome {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return .notFound }

        if let localMatch = await database.food(byBarcode: digits) {
            return .found(localMatch, .bundledDatabase)
        }

        return .notFound
    }

    private func firstBrand(from brands: String?) -> String? {
        guard let brands else { return nil }
        let first = brands.split(separator: ",").first.map(String.init)
        return stringValue(first)
    }

    private func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let text = stringValue(value), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text.replacingOccurrences(of: ",", with: "."))
        default:
            return nil
        }
    }

    private func positiveDouble(_ value: Any?) -> Double? {
        guard let number = doubleValue(value), number > 0 else { return nil }
        return number
    }

    private func parseServingQuantity(from servingSize: String?) -> Double? {
        guard let servingSize else { return nil }
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(g|gr|gram|grams|ml|milliliter|milliliters)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(servingSize.startIndex..<servingSize.endIndex, in: servingSize)
        guard let match = regex.firstMatch(in: servingSize, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: servingSize) else {
            return nil
        }
        return Double(servingSize[valueRange].replacingOccurrences(of: ",", with: "."))
    }

    private func convertUnit(_ value: Double, from sourceUnit: String?, to targetUnit: String) -> Double {
        let unit = (sourceUnit ?? targetUnit).lowercased()
        switch targetUnit {
        case "kcal":
            if unit == "kj" { return value / 4.184 }
            return value
        case "g":
            switch unit {
            case "mg": return value / 1000
            case "mcg", "µg", "ug": return value / 1_000_000
            case "kg": return value * 1000
            default: return value
            }
        case "mg":
            switch unit {
            case "g": return value * 1000
            case "mcg", "µg", "ug": return value / 1000
            case "kg": return value * 1_000_000
            default: return value
            }
        default:
            return value
        }
    }

    private func nutrientPerServing(
        _ nutriments: [String: Any],
        keys: [String],
        servingGrams: Double,
        targetUnit: String
    ) -> Double? {
        for key in keys {
            if let value = doubleValue(nutriments["\(key)_serving"]) {
                return convertUnit(value, from: stringValue(nutriments["\(key)_unit"]), to: targetUnit)
            }
        }

        for key in keys {
            if let value = doubleValue(nutriments["\(key)_100g"]) {
                let scaled = value * (servingGrams / 100)
                return convertUnit(scaled, from: stringValue(nutriments["\(key)_unit"]), to: targetUnit)
            }
        }

        for key in keys {
            if let value = doubleValue(nutriments[key]) {
                return convertUnit(value, from: stringValue(nutriments["\(key)_unit"]), to: targetUnit)
            }
        }

        return nil
    }

    private func formattedServing(_ grams: Double) -> String {
        if grams.rounded() == grams {
            return "\(Int(grams)) g"
        }
        return String(format: "%.1f g", grams)
    }
}
