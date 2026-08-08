import Foundation
import SwiftData

@MainActor
enum SyncMigrationService {
    struct TransferCounts {
        var inserted: Int = 0
        var updated: Int = 0
        var deleted: Int = 0

        var totalTouched: Int { inserted + updated + deleted }
    }

    struct Archive: Codable {
        var exportedAt: Date
        var sourceStoreKind: String
        var foodEntries: [FoodEntryRecord]
        var dailyGoals: [DailyGoalRecord]
        var weightEntries: [WeightEntryRecord]
        var chatMessages: [ChatMessageRecord]
        var customFoods: [CustomFoodRecord]
        var userProfiles: [UserProfileRecord]
        var waterEntries: [WaterEntryRecord]
        var loggingSessions: [LoggingSessionRecord]
        var agentTraceRecords: [AgentTraceRecordRecord]
        var resolvedFoodEvidence: [ResolvedFoodEvidenceRecord]
        var mealTemplates: [MealTemplateRecord]

        var totalRecordCount: Int {
            foodEntries.count
            + dailyGoals.count
            + weightEntries.count
            + chatMessages.count
            + customFoods.count
            + userProfiles.count
            + waterEntries.count
            + loggingSessions.count
            + agentTraceRecords.count
            + resolvedFoodEvidence.count
            + mealTemplates.count
        }

        var baseline: Baseline {
            Baseline(
                createdAt: exportedAt,
                sourceStoreKind: sourceStoreKind,
                foodEntryIDs: foodEntries.map(\.id),
                dailyGoalIDs: dailyGoals.map(\.id),
                weightEntryIDs: weightEntries.map(\.id),
                chatMessageIDs: chatMessages.map(\.id),
                customFoodIDs: customFoods.map(\.id),
                userProfileIDs: userProfiles.map(\.id),
                waterEntryIDs: waterEntries.map(\.id),
                loggingSessionIDs: loggingSessions.map(\.id),
                agentTraceRecordIDs: agentTraceRecords.map(\.id),
                resolvedFoodEvidenceIDs: resolvedFoodEvidence.map(\.id),
                mealTemplateIDs: mealTemplates.map(\.id)
            )
        }
    }

    struct Baseline: Codable {
        var createdAt: Date
        var sourceStoreKind: String
        var foodEntryIDs: [UUID]
        var dailyGoalIDs: [UUID]
        var weightEntryIDs: [UUID]
        var chatMessageIDs: [UUID]
        var customFoodIDs: [UUID]
        var userProfileIDs: [UUID]
        var waterEntryIDs: [UUID]
        var loggingSessionIDs: [UUID]
        var agentTraceRecordIDs: [UUID]
        var resolvedFoodEvidenceIDs: [UUID]
        var mealTemplateIDs: [UUID]
    }

    static func captureArchive(
        from container: ModelContainer,
        storeKind: ModelContainerManager.StoreKind
    ) throws -> Archive {
        let context = ModelContext(container)
        return Archive(
            exportedAt: .now,
            sourceStoreKind: storeKind.rawValue,
            foodEntries: try context.fetch(FetchDescriptor<FoodEntry>()).map(FoodEntryRecord.init),
            dailyGoals: try context.fetch(FetchDescriptor<DailyGoal>()).map(DailyGoalRecord.init),
            weightEntries: try context.fetch(FetchDescriptor<WeightEntry>()).map(WeightEntryRecord.init),
            chatMessages: try context.fetch(FetchDescriptor<ChatMessage>()).map(ChatMessageRecord.init),
            customFoods: try context.fetch(FetchDescriptor<CustomFood>()).map(CustomFoodRecord.init),
            userProfiles: try context.fetch(FetchDescriptor<UserProfile>()).map(UserProfileRecord.init),
            waterEntries: try context.fetch(FetchDescriptor<WaterEntry>()).map(WaterEntryRecord.init),
            loggingSessions: try context.fetch(FetchDescriptor<LoggingSession>()).map(LoggingSessionRecord.init),
            agentTraceRecords: try context.fetch(FetchDescriptor<AgentTraceRecord>()).map(AgentTraceRecordRecord.init),
            resolvedFoodEvidence: try context.fetch(FetchDescriptor<ResolvedFoodEvidence>()).map(ResolvedFoodEvidenceRecord.init),
            mealTemplates: try context.fetch(FetchDescriptor<MealTemplate>()).map(MealTemplateRecord.init)
        )
    }

    static func merge(
        archive: Archive,
        into container: ModelContainer,
        deletionBaseline: Baseline? = nil
    ) throws -> TransferCounts {
        let context = ModelContext(container)
        var counts = TransferCounts()

        let existingFoodEntries = try context.fetch(FetchDescriptor<FoodEntry>())
        upsert(
            context: context,
            existing: existingFoodEntries,
            records: archive.foodEntries,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingFoodEntries,
                baselineIDs: Set(deletionBaseline.foodEntryIDs),
                currentIDs: Set(archive.foodEntries.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingGoals = try context.fetch(FetchDescriptor<DailyGoal>())
        upsert(
            context: context,
            existing: existingGoals,
            records: archive.dailyGoals,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingGoals,
                baselineIDs: Set(deletionBaseline.dailyGoalIDs),
                currentIDs: Set(archive.dailyGoals.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingWeights = try context.fetch(FetchDescriptor<WeightEntry>())
        upsert(
            context: context,
            existing: existingWeights,
            records: archive.weightEntries,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingWeights,
                baselineIDs: Set(deletionBaseline.weightEntryIDs),
                currentIDs: Set(archive.weightEntries.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingMessages = try context.fetch(FetchDescriptor<ChatMessage>())
        upsert(
            context: context,
            existing: existingMessages,
            records: archive.chatMessages,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingMessages,
                baselineIDs: Set(deletionBaseline.chatMessageIDs),
                currentIDs: Set(archive.chatMessages.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingCustomFoods = try context.fetch(FetchDescriptor<CustomFood>())
        upsert(
            context: context,
            existing: existingCustomFoods,
            records: archive.customFoods,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingCustomFoods,
                baselineIDs: Set(deletionBaseline.customFoodIDs),
                currentIDs: Set(archive.customFoods.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingProfiles = try context.fetch(FetchDescriptor<UserProfile>())
        upsert(
            context: context,
            existing: existingProfiles,
            records: archive.userProfiles,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingProfiles,
                baselineIDs: Set(deletionBaseline.userProfileIDs),
                currentIDs: Set(archive.userProfiles.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingWaterEntries = try context.fetch(FetchDescriptor<WaterEntry>())
        upsert(
            context: context,
            existing: existingWaterEntries,
            records: archive.waterEntries,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingWaterEntries,
                baselineIDs: Set(deletionBaseline.waterEntryIDs),
                currentIDs: Set(archive.waterEntries.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingSessions = try context.fetch(FetchDescriptor<LoggingSession>())
        upsert(
            context: context,
            existing: existingSessions,
            records: archive.loggingSessions,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingSessions,
                baselineIDs: Set(deletionBaseline.loggingSessionIDs),
                currentIDs: Set(archive.loggingSessions.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingTraceRecords = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        upsert(
            context: context,
            existing: existingTraceRecords,
            records: archive.agentTraceRecords,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingTraceRecords,
                baselineIDs: Set(deletionBaseline.agentTraceRecordIDs),
                currentIDs: Set(archive.agentTraceRecords.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingEvidence = try context.fetch(FetchDescriptor<ResolvedFoodEvidence>())
        upsert(
            context: context,
            existing: existingEvidence,
            records: archive.resolvedFoodEvidence,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingEvidence,
                baselineIDs: Set(deletionBaseline.resolvedFoodEvidenceIDs),
                currentIDs: Set(archive.resolvedFoodEvidence.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        let existingTemplates = try context.fetch(FetchDescriptor<MealTemplate>())
        upsert(
            context: context,
            existing: existingTemplates,
            records: archive.mealTemplates,
            modelID: { $0.id },
            recordID: { $0.id },
            makeModel: { $0.restore() },
            updateModel: { model, record in record.apply(to: model) },
            counts: &counts
        )
        if let deletionBaseline {
            deleteMissing(
                existing: existingTemplates,
                baselineIDs: Set(deletionBaseline.mealTemplateIDs),
                currentIDs: Set(archive.mealTemplates.map(\.id)),
                modelID: { $0.id },
                context: context,
                counts: &counts
            )
        }

        try context.save()
        return counts
    }

    static func replaceStore(
        with archive: Archive,
        in container: ModelContainer
    ) throws -> TransferCounts {
        let context = ModelContext(container)
        try deleteAllRecords(in: context)
        try context.save()
        return try merge(archive: archive, into: container)
    }

    static func writeArchive(_ archive: Archive, reason: String) throws -> URL {
        let directory = try syncFilesDirectory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: archive.exportedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(reason)-\(timestamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: url, options: .atomic)
        try protectSyncFile(at: url)
        try pruneArchivedBackups(in: directory, keepingMostRecent: 8)
        return url
    }

    static func saveBaseline(_ baseline: Baseline) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = try baselineURL()
        try encoder.encode(baseline).write(to: url, options: .atomic)
        try protectSyncFile(at: url)
    }

    static func loadBaseline() -> Baseline? {
        guard let url = try? baselineURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Baseline.self, from: data)
    }

    static func clearBaseline() {
        guard let url = try? baselineURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func syncFilesDirectory() throws -> URL {
        let baseDirectory = try applicationSupportDirectory()
        let directory = baseDirectory.appendingPathComponent("SyncState", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func baselineURL() throws -> URL {
        try syncFilesDirectory().appendingPathComponent("local-cloud-baseline.json")
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "SyncMigrationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory is unavailable."])
        }
        let directory = url.appendingPathComponent("Nomva", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func deleteAllRecords(in context: ModelContext) throws {
        try context.fetch(FetchDescriptor<FoodEntry>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<DailyGoal>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<WeightEntry>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ChatMessage>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CustomFood>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<UserProfile>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<WaterEntry>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LoggingSession>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<AgentTraceRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ResolvedFoodEvidence>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<MealTemplate>()).forEach(context.delete)
    }

    private static func upsert<Model: PersistentModel, Record, ID: Hashable>(
        context: ModelContext,
        existing: [Model],
        records: [Record],
        modelID: (Model) -> ID,
        recordID: (Record) -> ID,
        makeModel: (Record) -> Model,
        updateModel: (Model, Record) -> Void,
        counts: inout TransferCounts
    ) {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { (modelID($0), $0) })
        for record in records {
            if let current = existingByID[recordID(record)] {
                updateModel(current, record)
                counts.updated += 1
            } else {
                context.insert(makeModel(record))
                counts.inserted += 1
            }
        }
    }

    private static func deleteMissing<Model: PersistentModel>(
        existing: [Model],
        baselineIDs: Set<UUID>,
        currentIDs: Set<UUID>,
        modelID: (Model) -> UUID,
        context: ModelContext,
        counts: inout TransferCounts
    ) {
        let idsToDelete = baselineIDs.subtracting(currentIDs)
        guard !idsToDelete.isEmpty else { return }
        for model in existing where idsToDelete.contains(modelID(model)) {
            context.delete(model)
            counts.deleted += 1
        }
    }

    private static func protectSyncFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func pruneArchivedBackups(in directory: URL, keepingMostRecent limit: Int) throws {
        guard limit > 0 else { return }

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" && $0.lastPathComponent != "local-cloud-baseline.json" }
        .sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        guard backups.count > limit else { return }

        for backup in backups.dropFirst(limit) {
            try? FileManager.default.removeItem(at: backup)
        }
    }
}

struct FoodEntryRecord: Codable {
    var id: UUID
    var name: String
    var brand: String?
    var meal: String
    var date: Date
    var portionGrams: Double
    var portionDescription: String
    var servings: Double
    var servingUnit: String
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double
    var sugarG: Double
    var sodiumMg: Double
    var saturatedFatG: Double?
    var transFatG: Double?
    var cholesterolMg: Double?
    var addedSugarG: Double?
    var vitaminDMcg: Double?
    var calciumMg: Double?
    var ironMg: Double?
    var potassiumMg: Double?
    var vitaminAMcgRAE: Double?
    var vitaminCMg: Double?
    var vitaminB12Mcg: Double?
    var folateMcgDFE: Double?
    var magnesiumMg: Double?
    var zincMg: Double?
    var caloriesPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double
    var fiberPer100g: Double
    var sugarPer100g: Double
    var sodiumPer100g: Double
    var saturatedFatPer100g: Double?
    var transFatPer100g: Double?
    var cholesterolPer100g: Double?
    var addedSugarPer100g: Double?
    var vitaminDPer100g: Double?
    var calciumPer100g: Double?
    var ironPer100g: Double?
    var potassiumPer100g: Double?
    var vitaminAPer100g: Double?
    var vitaminCPer100g: Double?
    var vitaminB12Per100g: Double?
    var folatePer100g: Double?
    var magnesiumPer100g: Double?
    var zincPer100g: Double?
    var rawUserInput: String
    var fdcId: Int?
    var foodDatabaseId: Int?
    var source: String?
    var barcode: String?
    var isFavorite: Bool

    init(_ model: FoodEntry) {
        id = model.id
        name = model.name
        brand = model.brand
        meal = model.meal
        date = model.date
        portionGrams = model.portionGrams
        portionDescription = model.portionDescription
        servings = model.servings
        servingUnit = model.servingUnit
        calories = model.calories
        proteinG = model.proteinG
        carbsG = model.carbsG
        fatG = model.fatG
        fiberG = model.fiberG
        sugarG = model.sugarG
        sodiumMg = model.sodiumMg
        saturatedFatG = model.saturatedFatG
        transFatG = model.transFatG
        cholesterolMg = model.cholesterolMg
        addedSugarG = model.addedSugarG
        vitaminDMcg = model.vitaminDMcg
        calciumMg = model.calciumMg
        ironMg = model.ironMg
        potassiumMg = model.potassiumMg
        vitaminAMcgRAE = model.vitaminAMcgRAE
        vitaminCMg = model.vitaminCMg
        vitaminB12Mcg = model.vitaminB12Mcg
        folateMcgDFE = model.folateMcgDFE
        magnesiumMg = model.magnesiumMg
        zincMg = model.zincMg
        caloriesPer100g = model.caloriesPer100g
        proteinPer100g = model.proteinPer100g
        carbsPer100g = model.carbsPer100g
        fatPer100g = model.fatPer100g
        fiberPer100g = model.fiberPer100g
        sugarPer100g = model.sugarPer100g
        sodiumPer100g = model.sodiumPer100g
        saturatedFatPer100g = model.saturatedFatPer100g
        transFatPer100g = model.transFatPer100g
        cholesterolPer100g = model.cholesterolPer100g
        addedSugarPer100g = model.addedSugarPer100g
        vitaminDPer100g = model.vitaminDPer100g
        calciumPer100g = model.calciumPer100g
        ironPer100g = model.ironPer100g
        potassiumPer100g = model.potassiumPer100g
        vitaminAPer100g = model.vitaminAPer100g
        vitaminCPer100g = model.vitaminCPer100g
        vitaminB12Per100g = model.vitaminB12Per100g
        folatePer100g = model.folatePer100g
        magnesiumPer100g = model.magnesiumPer100g
        zincPer100g = model.zincPer100g
        rawUserInput = model.rawUserInput
        fdcId = model.fdcId
        foodDatabaseId = model.foodDatabaseId
        source = model.source
        barcode = model.barcode
        isFavorite = model.isFavorite
    }

    func restore() -> FoodEntry {
        let model = FoodEntry(
            name: name,
            brand: brand,
            meal: meal,
            date: date,
            portionGrams: portionGrams,
            portionDescription: portionDescription,
            servings: servings,
            servingUnit: servingUnit,
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            sugarG: sugarG,
            sodiumMg: sodiumMg,
            saturatedFatG: saturatedFatG,
            transFatG: transFatG,
            cholesterolMg: cholesterolMg,
            addedSugarG: addedSugarG,
            vitaminDMcg: vitaminDMcg,
            calciumMg: calciumMg,
            ironMg: ironMg,
            potassiumMg: potassiumMg,
            vitaminAMcgRAE: vitaminAMcgRAE,
            vitaminCMg: vitaminCMg,
            vitaminB12Mcg: vitaminB12Mcg,
            folateMcgDFE: folateMcgDFE,
            magnesiumMg: magnesiumMg,
            zincMg: zincMg,
            caloriesPer100g: caloriesPer100g,
            proteinPer100g: proteinPer100g,
            carbsPer100g: carbsPer100g,
            fatPer100g: fatPer100g,
            fiberPer100g: fiberPer100g,
            sugarPer100g: sugarPer100g,
            sodiumPer100g: sodiumPer100g,
            saturatedFatPer100g: saturatedFatPer100g,
            transFatPer100g: transFatPer100g,
            cholesterolPer100g: cholesterolPer100g,
            addedSugarPer100g: addedSugarPer100g,
            vitaminDPer100g: vitaminDPer100g,
            calciumPer100g: calciumPer100g,
            ironPer100g: ironPer100g,
            potassiumPer100g: potassiumPer100g,
            vitaminAPer100g: vitaminAPer100g,
            vitaminCPer100g: vitaminCPer100g,
            vitaminB12Per100g: vitaminB12Per100g,
            folatePer100g: folatePer100g,
            magnesiumPer100g: magnesiumPer100g,
            zincPer100g: zincPer100g,
            rawUserInput: rawUserInput,
            fdcId: fdcId,
            foodDatabaseId: foodDatabaseId,
            source: source,
            barcode: barcode
        )
        apply(to: model)
        return model
    }

    func apply(to model: FoodEntry) {
        model.id = id
        model.name = name
        model.brand = brand
        model.meal = meal
        model.date = date
        model.portionGrams = portionGrams
        model.portionDescription = portionDescription
        model.servings = servings
        model.servingUnit = servingUnit
        model.calories = calories
        model.proteinG = proteinG
        model.carbsG = carbsG
        model.fatG = fatG
        model.fiberG = fiberG
        model.sugarG = sugarG
        model.sodiumMg = sodiumMg
        model.saturatedFatG = saturatedFatG
        model.transFatG = transFatG
        model.cholesterolMg = cholesterolMg
        model.addedSugarG = addedSugarG
        model.vitaminDMcg = vitaminDMcg
        model.calciumMg = calciumMg
        model.ironMg = ironMg
        model.potassiumMg = potassiumMg
        model.vitaminAMcgRAE = vitaminAMcgRAE
        model.vitaminCMg = vitaminCMg
        model.vitaminB12Mcg = vitaminB12Mcg
        model.folateMcgDFE = folateMcgDFE
        model.magnesiumMg = magnesiumMg
        model.zincMg = zincMg
        model.caloriesPer100g = caloriesPer100g
        model.proteinPer100g = proteinPer100g
        model.carbsPer100g = carbsPer100g
        model.fatPer100g = fatPer100g
        model.fiberPer100g = fiberPer100g
        model.sugarPer100g = sugarPer100g
        model.sodiumPer100g = sodiumPer100g
        model.saturatedFatPer100g = saturatedFatPer100g
        model.transFatPer100g = transFatPer100g
        model.cholesterolPer100g = cholesterolPer100g
        model.addedSugarPer100g = addedSugarPer100g
        model.vitaminDPer100g = vitaminDPer100g
        model.calciumPer100g = calciumPer100g
        model.ironPer100g = ironPer100g
        model.potassiumPer100g = potassiumPer100g
        model.vitaminAPer100g = vitaminAPer100g
        model.vitaminCPer100g = vitaminCPer100g
        model.vitaminB12Per100g = vitaminB12Per100g
        model.folatePer100g = folatePer100g
        model.magnesiumPer100g = magnesiumPer100g
        model.zincPer100g = zincPer100g
        model.rawUserInput = rawUserInput
        model.fdcId = fdcId
        model.foodDatabaseId = foodDatabaseId
        model.source = source
        model.barcode = barcode
        model.isFavorite = isFavorite
    }
}

struct DailyGoalRecord: Codable {
    var id: UUID
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var createdAt: Date
    var isActive: Bool

    init(_ model: DailyGoal) {
        id = model.id
        calories = model.calories
        protein = model.protein
        carbs = model.carbs
        fat = model.fat
        fiber = model.fiber
        createdAt = model.createdAt
        isActive = model.isActive
    }

    func restore() -> DailyGoal {
        let model = DailyGoal(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber)
        apply(to: model)
        return model
    }

    func apply(to model: DailyGoal) {
        model.id = id
        model.calories = calories
        model.protein = protein
        model.carbs = carbs
        model.fat = fat
        model.fiber = fiber
        model.createdAt = createdAt
        model.isActive = isActive
    }
}

struct WeightEntryRecord: Codable {
    var id: UUID
    var date: Date
    var weightLbs: Double
    var note: String?
    var sourceRaw: String?
    var sourceName: String?
    var externalIdentifier: String?
    var healthSyncVersion: Int?

    init(_ model: WeightEntry) {
        id = model.id
        date = model.date
        weightLbs = model.weightLbs
        note = model.note
        sourceRaw = model.sourceRaw
        sourceName = model.sourceName
        externalIdentifier = model.externalIdentifier
        healthSyncVersion = model.healthSyncVersion
    }

    func restore() -> WeightEntry {
        let model = WeightEntry(
            date: date,
            weightLbs: weightLbs,
            note: note,
            source: WeightDataSource(rawValue: sourceRaw ?? "") ?? .nomva,
            sourceName: sourceName,
            externalIdentifier: externalIdentifier,
            healthSyncVersion: healthSyncVersion
        )
        apply(to: model)
        return model
    }

    func apply(to model: WeightEntry) {
        model.id = id
        model.date = date
        model.weightLbs = weightLbs
        model.note = note
        model.sourceRaw = sourceRaw
        model.sourceName = sourceName
        model.externalIdentifier = externalIdentifier
        model.healthSyncVersion = healthSyncVersion
    }
}

struct ChatMessageRecord: Codable {
    var id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var dayDate: Date

    init(_ model: ChatMessage) {
        id = model.id
        role = model.role
        content = model.content
        timestamp = model.timestamp
        dayDate = model.dayDate
    }

    func restore() -> ChatMessage {
        let model = ChatMessage(role: role, content: content, timestamp: timestamp, dayDate: dayDate)
        apply(to: model)
        return model
    }

    func apply(to model: ChatMessage) {
        model.id = id
        model.role = role
        model.content = content
        model.timestamp = timestamp
        model.dayDate = dayDate
    }
}

struct CustomFoodRecord: Codable {
    var id: UUID
    var name: String
    var brand: String?
    var servingDesc: String
    var servingGrams: Double
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double
    var barcode: String?
    var createdAt: Date

    init(_ model: CustomFood) {
        id = model.id
        name = model.name
        brand = model.brand
        servingDesc = model.servingDesc
        servingGrams = model.servingGrams
        calories = model.calories
        proteinG = model.proteinG
        carbsG = model.carbsG
        fatG = model.fatG
        fiberG = model.fiberG
        barcode = model.barcode
        createdAt = model.createdAt
    }

    func restore() -> CustomFood {
        let model = CustomFood(
            name: name,
            brand: brand,
            servingDesc: servingDesc,
            servingGrams: servingGrams,
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            barcode: barcode
        )
        apply(to: model)
        return model
    }

    func apply(to model: CustomFood) {
        model.id = id
        model.name = name
        model.brand = brand
        model.servingDesc = servingDesc
        model.servingGrams = servingGrams
        model.calories = calories
        model.proteinG = proteinG
        model.carbsG = carbsG
        model.fatG = fatG
        model.fiberG = fiberG
        model.barcode = barcode
        model.createdAt = createdAt
    }
}

struct UserProfileRecord: Codable {
    var id: UUID
    var biologicalSex: String
    var birthYear: Int
    var heightInches: Int
    var activityLevel: String
    var weightGoal: String
    var onboardingComplete: Bool
    var createdAt: Date

    init(_ model: UserProfile) {
        id = model.id
        biologicalSex = model.biologicalSex
        birthYear = model.birthYear
        heightInches = model.heightInches
        activityLevel = model.activityLevel
        weightGoal = model.weightGoal
        onboardingComplete = model.onboardingComplete
        createdAt = model.createdAt
    }

    func restore() -> UserProfile {
        let model = UserProfile(
            biologicalSex: biologicalSex,
            birthYear: birthYear,
            heightInches: heightInches,
            activityLevel: activityLevel,
            weightGoal: weightGoal
        )
        apply(to: model)
        return model
    }

    func apply(to model: UserProfile) {
        model.id = id
        model.biologicalSex = biologicalSex
        model.birthYear = birthYear
        model.heightInches = heightInches
        model.activityLevel = activityLevel
        model.weightGoal = weightGoal
        model.onboardingComplete = onboardingComplete
        model.createdAt = createdAt
    }
}

struct WaterEntryRecord: Codable {
    var id: UUID
    var date: Date
    var amountOz: Double

    init(_ model: WaterEntry) {
        id = model.id
        date = model.date
        amountOz = model.amountOz
    }

    func restore() -> WaterEntry {
        let model = WaterEntry(amountOz: amountOz)
        apply(to: model)
        return model
    }

    func apply(to model: WaterEntry) {
        model.id = id
        model.date = date
        model.amountOz = amountOz
    }
}

struct LoggingSessionRecord: Codable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var dayDate: Date
    var status: String
    var serializedState: String

    init(_ model: LoggingSession) {
        id = model.id
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        dayDate = model.dayDate
        status = model.status
        serializedState = model.serializedState
    }

    func restore() -> LoggingSession {
        let fallbackState = AgentTaskState(
            taskId: UUID(),
            status: status,
            intent: nil,
            originalUserMessage: "",
            latestUserMessage: "",
            meal: nil,
            pendingDescriptions: [],
            unresolvedSlots: [],
            lastQuestion: nil,
            correctionTargetName: nil,
            lastToolContext: nil,
            candidateGroups: []
        )
        let model = LoggingSession(dayDate: dayDate, state: fallbackState)
        apply(to: model)
        return model
    }

    func apply(to model: LoggingSession) {
        model.id = id
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        model.dayDate = dayDate
        model.status = status
        model.serializedState = serializedState
    }
}

struct AgentTraceRecordRecord: Codable {
    var id: UUID
    var createdAt: Date
    var dayDate: Date
    var userMessage: String
    var detectedIntent: String
    var providerType: String
    var usedFallback: Bool
    var rawModelAction: String?
    var routedAction: String?
    var finalAction: String
    var validationSummary: String
    var searchSummary: String?
    var candidateSummary: String?
    var rawModelResponse: String?
    var finalReply: String?

    init(_ model: AgentTraceRecord) {
        id = model.id
        createdAt = model.createdAt
        dayDate = model.dayDate
        userMessage = model.userMessage
        detectedIntent = model.detectedIntent
        providerType = model.providerType
        usedFallback = model.usedFallback
        rawModelAction = model.rawModelAction
        routedAction = model.routedAction
        finalAction = model.finalAction
        validationSummary = model.validationSummary
        searchSummary = model.searchSummary
        candidateSummary = model.candidateSummary
        rawModelResponse = model.rawModelResponse
        finalReply = model.finalReply
    }

    func restore() -> AgentTraceRecord {
        let model = AgentTraceRecord(
            dayDate: dayDate,
            userMessage: userMessage,
            detectedIntent: detectedIntent,
            providerType: providerType,
            usedFallback: usedFallback,
            rawModelAction: rawModelAction,
            routedAction: routedAction,
            finalAction: finalAction,
            validationSummary: validationSummary,
            searchSummary: searchSummary,
            candidateSummary: candidateSummary,
            rawModelResponse: rawModelResponse,
            finalReply: finalReply
        )
        apply(to: model)
        return model
    }

    func apply(to model: AgentTraceRecord) {
        model.id = id
        model.createdAt = createdAt
        model.dayDate = dayDate
        model.userMessage = userMessage
        model.detectedIntent = detectedIntent
        model.providerType = providerType
        model.usedFallback = usedFallback
        model.rawModelAction = rawModelAction
        model.routedAction = routedAction
        model.finalAction = finalAction
        model.validationSummary = validationSummary
        model.searchSummary = searchSummary
        model.candidateSummary = candidateSummary
        model.rawModelResponse = rawModelResponse
        model.finalReply = finalReply
    }
}

struct ResolvedFoodEvidenceRecord: Codable {
    var id: UUID
    var createdAt: Date
    var dayDate: Date
    var foodEntryId: UUID
    var sourceType: String
    var fdcId: Int?
    var matchedName: String
    var matchedBrand: String?
    var searchTerms: String
    var candidateSummary: String
    var resolutionConfidence: Double
    var wasClarified: Bool
    var quality: String?
    var sourceURL: String?
    var sourceTitle: String?
    var evidence: String?

    init(_ model: ResolvedFoodEvidence) {
        id = model.id
        createdAt = model.createdAt
        dayDate = model.dayDate
        foodEntryId = model.foodEntryId
        sourceType = model.sourceType
        fdcId = model.fdcId
        matchedName = model.matchedName
        matchedBrand = model.matchedBrand
        searchTerms = model.searchTerms
        candidateSummary = model.candidateSummary
        resolutionConfidence = model.resolutionConfidence
        wasClarified = model.wasClarified
        quality = model.quality
        sourceURL = model.sourceURL
        sourceTitle = model.sourceTitle
        evidence = model.evidence
    }

    func restore() -> ResolvedFoodEvidence {
        let model = ResolvedFoodEvidence(
            dayDate: dayDate,
            foodEntryId: foodEntryId,
            sourceType: sourceType,
            fdcId: fdcId,
            matchedName: matchedName,
            matchedBrand: matchedBrand,
            searchTerms: searchTerms,
            candidateSummary: candidateSummary,
            resolutionConfidence: resolutionConfidence,
            wasClarified: wasClarified,
            quality: quality,
            sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            evidence: evidence
        )
        apply(to: model)
        return model
    }

    func apply(to model: ResolvedFoodEvidence) {
        model.id = id
        model.createdAt = createdAt
        model.dayDate = dayDate
        model.foodEntryId = foodEntryId
        model.sourceType = sourceType
        model.fdcId = fdcId
        model.matchedName = matchedName
        model.matchedBrand = matchedBrand
        model.searchTerms = searchTerms
        model.candidateSummary = candidateSummary
        model.resolutionConfidence = resolutionConfidence
        model.wasClarified = wasClarified
        model.quality = quality
        model.sourceURL = sourceURL
        model.sourceTitle = sourceTitle
        model.evidence = evidence
    }
}

struct MealTemplateRecord: Codable {
    var id: UUID
    var name: String
    var items: [MealTemplate.TemplateItem]
    var createdAt: Date

    init(_ model: MealTemplate) {
        id = model.id
        name = model.name
        items = model.items
        createdAt = model.createdAt
    }

    func restore() -> MealTemplate {
        let model = MealTemplate(name: name, items: items)
        apply(to: model)
        return model
    }

    func apply(to model: MealTemplate) {
        model.id = id
        model.name = name
        model.items = items
        model.createdAt = createdAt
    }
}
