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
    private var verifiedRowCount: Int?

    init(databaseURL: URL? = Bundle.main.url(forResource: "foods", withExtension: "sqlite")) {
        guard let databaseURL else {
            print("DatabaseManager: foods.sqlite not found in bundle")
            return
        }
        // Apple can expose the signed bundle through /var -> /private/var.
        // Resolve that trusted bundle path before SQLite's no-symlink check.
        let dbPath = databaseURL.resolvingSymlinksInPath().path
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

        guard let identity = BarcodeIdentity(barcode) else { return nil }
        let aliases = identity.aliases
        let placeholders = Array(repeating: "?", count: aliases.count).joined(separator: ",")
        let sql = """
            SELECT \(foodSelectColumns) FROM foods f
            WHERE f.barcode IN (\(placeholders))
            ORDER BY CASE WHEN f.barcode = ? THEN 0 ELSE 1 END,
                     CASE WHEN f.source = 'open_food_facts' THEN 1 ELSE 0 END
            LIMIT 1
        """
        var stmt: OpaquePointer?
        var result: FoodItem?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (index, alias) in aliases.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), alias, -1, sqliteTransient)
            }
            sqlite3_bind_text(stmt, Int32(aliases.count + 1), identity.digits, -1, sqliteTransient)
            if sqlite3_step(stmt) == SQLITE_ROW { result = FoodItem(from: stmt!) }
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
        if let verifiedRowCount { total = verifiedRowCount }
        else {
            var countStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM foods", -1, &countStatement, nil) == SQLITE_OK,
               sqlite3_step(countStatement) == SQLITE_ROW {
                total = Int(sqlite3_column_int64(countStatement, 0))
                verifiedRowCount = total
            }
            sqlite3_finalize(countStatement)
        }
        return (total, buildDate)
    }
}
