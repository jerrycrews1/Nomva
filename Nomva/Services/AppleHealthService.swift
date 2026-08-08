import Foundation
import HealthKit
import SwiftData

enum AppleHealthAuthorizationState: Sendable {
    case unavailable
    case shouldRequest
    case ready
    case unknown
}

struct AppleHealthActivitySummary: Equatable, Sendable {
    let averageActiveCalories: Double
    let sampledDays: Int
    let windowDays: Int
    let startDate: Date
    let endDate: Date
}

struct AppleHealthWeightSample: Equatable, Sendable {
    let externalIdentifier: String
    let date: Date
    let weightLbs: Double
    let sourceName: String
    let nomvaEntryID: UUID?
}

struct AppleHealthWeightWrite: Equatable, Sendable {
    let entryID: UUID
    let date: Date
    let weightLbs: Double
    let syncVersion: Int
}

struct WeightImportCandidate: Equatable, Sendable {
    let source: WeightDataSource
    let externalIdentifier: String
    let date: Date
    let weightLbs: Double
    let sourceName: String
    let nomvaEntryID: UUID?
}

struct WeightImportResult: Equatable, Sendable {
    var inserted = 0
    var updated = 0
    var skipped = 0

    var imported: Int { inserted + updated }
}

enum AppleHealthServiceError: LocalizedError {
    case unavailable
    case unsupportedDataType
    case weightPermissionDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Health is not available on this device."
        case .unsupportedDataType:
            return "The requested Apple Health data is not supported on this device."
        case .weightPermissionDenied:
            return "Nomva does not have permission to save weight in Apple Health."
        }
    }
}

enum AppleHealthService {
    private static let healthStore = HKHealthStore()
    private static let nomvaEntryMetadataKey = "com.nomva.weight.entry-id"

    private static var activeEnergyType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
    }

    private static var bodyMassType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .bodyMass)
    }

    static func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    static func requestStatus() async throws -> AppleHealthAuthorizationState {
        guard isAvailable() else {
            return .unavailable
        }

        guard let activeEnergyType else {
            return .unknown
        }

        let readTypes: Set<HKObjectType> = [activeEnergyType]
        return try await withCheckedThrowingContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                switch status {
                case .shouldRequest:
                    continuation.resume(returning: .shouldRequest)
                case .unnecessary:
                    continuation.resume(returning: .ready)
                case .unknown:
                    continuation.resume(returning: .unknown)
                @unknown default:
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    static func requestAuthorization() async throws {
        guard isAvailable() else {
            throw AppleHealthServiceError.unavailable
        }

        guard let activeEnergyType else {
            throw AppleHealthServiceError.unsupportedDataType
        }

        let readTypes: Set<HKObjectType> = [activeEnergyType]
        try await healthStore.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes)
    }

    static func weightWriteAuthorizationStatus() -> HKAuthorizationStatus {
        guard let bodyMassType else { return .sharingDenied }
        return healthStore.authorizationStatus(for: bodyMassType)
    }

    static func requestWeightReadAuthorization() async throws {
        guard isAvailable() else {
            throw AppleHealthServiceError.unavailable
        }
        guard let bodyMassType else {
            throw AppleHealthServiceError.unsupportedDataType
        }

        try await healthStore.requestAuthorization(
            toShare: [],
            read: [bodyMassType]
        )
    }

    static func requestWeightWriteAuthorization() async throws {
        guard isAvailable() else {
            throw AppleHealthServiceError.unavailable
        }
        guard let bodyMassType else {
            throw AppleHealthServiceError.unsupportedDataType
        }

        try await healthStore.requestAuthorization(
            toShare: [bodyMassType],
            read: []
        )
    }

    static func fetchWeightSamples(since startDate: Date? = nil) async throws -> [AppleHealthWeightSample] {
        guard isAvailable() else {
            throw AppleHealthServiceError.unavailable
        }
        guard let bodyMassType else {
            throw AppleHealthServiceError.unsupportedDataType
        }

        let predicate = startDate.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate)
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: bodyMassType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let mapped = (samples as? [HKQuantitySample] ?? []).compactMap { sample -> AppleHealthWeightSample? in
                    let pounds = sample.quantity.doubleValue(for: .pound())
                    guard pounds.isFinite, pounds >= 40, pounds <= 1_200 else { return nil }

                    let entryID = (sample.metadata?[nomvaEntryMetadataKey] as? String)
                        .flatMap(UUID.init(uuidString:))
                    return AppleHealthWeightSample(
                        externalIdentifier: "apple:\(sample.uuid.uuidString.lowercased())",
                        date: sample.startDate,
                        weightLbs: pounds,
                        sourceName: sample.sourceRevision.source.name,
                        nomvaEntryID: entryID
                    )
                }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
    }

    @discardableResult
    static func saveWeight(
        entryID: UUID,
        date: Date,
        weightLbs: Double,
        syncVersion: Int
    ) async throws -> String {
        let identifiers = try await saveWeights([
            AppleHealthWeightWrite(
                entryID: entryID,
                date: date,
                weightLbs: weightLbs,
                syncVersion: syncVersion
            )
        ])
        guard let identifier = identifiers[entryID] else {
            throw AppleHealthServiceError.weightPermissionDenied
        }
        return identifier
    }

    static func saveWeights(_ writes: [AppleHealthWeightWrite]) async throws -> [UUID: String] {
        guard !writes.isEmpty else { return [:] }
        guard isAvailable() else {
            throw AppleHealthServiceError.unavailable
        }
        guard let bodyMassType else {
            throw AppleHealthServiceError.unsupportedDataType
        }
        guard weightWriteAuthorizationStatus() == .sharingAuthorized else {
            throw AppleHealthServiceError.weightPermissionDenied
        }

        let pairs: [(write: AppleHealthWeightWrite, sample: HKQuantitySample)] = try writes.map { write in
            guard write.weightLbs.isFinite, write.weightLbs >= 40, write.weightLbs <= 1_200 else {
                throw AppleHealthServiceError.unsupportedDataType
            }
            let sample = HKQuantitySample(
                type: bodyMassType,
                quantity: HKQuantity(unit: .pound(), doubleValue: write.weightLbs),
                start: write.date,
                end: write.date,
                metadata: [
                    HKMetadataKeySyncIdentifier: "com.nomva.weight.\(write.entryID.uuidString.lowercased())",
                    HKMetadataKeySyncVersion: NSNumber(value: write.syncVersion),
                    HKMetadataKeyWasUserEntered: true,
                    nomvaEntryMetadataKey: write.entryID.uuidString,
                ]
            )
            return (write, sample)
        }
        let objects: [HKObject] = pairs.map(\.sample)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(objects) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AppleHealthServiceError.weightPermissionDenied)
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: pairs.map {
            ($0.write.entryID, "apple:\($0.sample.uuid.uuidString.lowercased())")
        })
    }

    static func fetchAverageActiveCalories(windowDays: Int = 28) async throws -> AppleHealthActivitySummary? {
        guard isAvailable() else {
            throw AppleHealthServiceError.unavailable
        }

        guard let activeEnergyType else {
            throw AppleHealthServiceError.unsupportedDataType
        }

        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -windowDays, to: endDate) ?? endDate
        let interval = DateComponents(day: 1)
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: activeEnergyType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: endDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let collection else {
                    continuation.resume(returning: nil)
                    return
                }

                var dailyValues: [Double] = []
                collection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                    guard let quantity = statistics.sumQuantity() else { return }
                    dailyValues.append(quantity.doubleValue(for: .kilocalorie()))
                }

                guard !dailyValues.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let averageActiveCalories = dailyValues.reduce(0, +) / Double(dailyValues.count)
                continuation.resume(returning: AppleHealthActivitySummary(
                    averageActiveCalories: averageActiveCalories,
                    sampledDays: dailyValues.count,
                    windowDays: windowDays,
                    startDate: startDate,
                    endDate: endDate
                ))
            }

            healthStore.execute(query)
        }
    }
}

enum WeightSyncPreferences {
    static let appleHealthImportKey = "weight_sync_apple_health_import"
    static let appleHealthExportKey = "weight_sync_apple_health_export"
    static let garminImportKey = "weight_sync_garmin_import"
    static let lastErrorKey = "weight_sync_last_error"

    static var appleHealthImportEnabled: Bool {
        UserDefaults.standard.bool(forKey: appleHealthImportKey)
    }

    static var appleHealthExportEnabled: Bool {
        UserDefaults.standard.bool(forKey: appleHealthExportKey)
    }

    static var garminImportEnabled: Bool {
        UserDefaults.standard.bool(forKey: garminImportKey)
    }

    static func record(error: Error?) {
        UserDefaults.standard.set(error?.localizedDescription, forKey: lastErrorKey)
    }
}

enum WeightImportPlanner {
    static let duplicateTimeTolerance: TimeInterval = 5 * 60
    static let duplicateWeightToleranceLbs = 0.15

    static func duplicateIndex(
        for candidate: WeightImportCandidate,
        in snapshots: [(externalIdentifier: String?, date: Date, weightLbs: Double)]
    ) -> Int? {
        if let exact = snapshots.firstIndex(where: {
            $0.externalIdentifier == candidate.externalIdentifier
        }) {
            return exact
        }

        return snapshots.firstIndex(where: {
            abs($0.date.timeIntervalSince(candidate.date)) <= duplicateTimeTolerance &&
            abs($0.weightLbs - candidate.weightLbs) <= duplicateWeightToleranceLbs
        })
    }
}

@MainActor
enum WeightSyncCoordinator {
    static func importAppleHealth(into modelContext: ModelContext) async throws -> WeightImportResult {
        let samples = try await AppleHealthService.fetchWeightSamples()
        let candidates = samples.map {
            WeightImportCandidate(
                source: .appleHealth,
                externalIdentifier: $0.externalIdentifier,
                date: $0.date,
                weightLbs: $0.weightLbs,
                sourceName: $0.sourceName,
                nomvaEntryID: $0.nomvaEntryID
            )
        }
        return try apply(candidates, to: modelContext)
    }

    static func importGarmin(
        into modelContext: ModelContext,
        uploadLookbackDays: Int
    ) async throws -> WeightImportResult {
        let samples = try await GarminCloudService().fetchWeights(
            uploadLookbackDays: uploadLookbackDays
        )
        let candidates: [WeightImportCandidate] = samples.compactMap { sample in
            guard let measuredDate = sample.measuredDate else { return nil }
            return WeightImportCandidate(
                source: .garmin,
                externalIdentifier: "garmin:\(sample.id)",
                date: measuredDate,
                weightLbs: sample.weightKg / 0.45359237,
                sourceName: "Garmin Connect",
                nomvaEntryID: nil
            )
        }
        return try apply(candidates, to: modelContext)
    }

    static func exportToAppleHealth(_ entry: WeightEntry, in modelContext: ModelContext) async throws {
        guard entry.dataSource == .nomva,
              WeightSyncPreferences.appleHealthExportEnabled else { return }

        let version = max(1, (entry.healthSyncVersion ?? 0) + 1)
        let externalIdentifier = try await AppleHealthService.saveWeight(
            entryID: entry.id,
            date: entry.date,
            weightLbs: entry.weightLbs,
            syncVersion: version
        )
        entry.healthSyncVersion = version
        entry.externalIdentifier = externalIdentifier
        try modelContext.save()
        WeightSyncPreferences.record(error: nil)
    }

    static func exportAllNomvaWeightsToAppleHealth(
        from entries: [WeightEntry],
        in modelContext: ModelContext
    ) async throws -> Int {
        guard WeightSyncPreferences.appleHealthExportEnabled else { return 0 }
        let exportable = entries
            .filter { $0.dataSource == .nomva }
            .sorted(by: { $0.date < $1.date })
        var exported = 0

        for start in stride(from: 0, to: exportable.count, by: 200) {
            let chunk = Array(exportable[start..<min(start + 200, exportable.count)])
            let writes = chunk.map {
                AppleHealthWeightWrite(
                    entryID: $0.id,
                    date: $0.date,
                    weightLbs: $0.weightLbs,
                    syncVersion: max(1, ($0.healthSyncVersion ?? 0) + 1)
                )
            }
            let identifiers = try await AppleHealthService.saveWeights(writes)
            for (entry, write) in zip(chunk, writes) {
                entry.healthSyncVersion = write.syncVersion
                entry.externalIdentifier = identifiers[entry.id]
                exported += 1
            }
        }
        try modelContext.save()
        WeightSyncPreferences.record(error: nil)
        return exported
    }

    static func apply(
        _ candidates: [WeightImportCandidate],
        to modelContext: ModelContext
    ) throws -> WeightImportResult {
        var entries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
        var result = WeightImportResult()

        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            guard candidate.weightLbs.isFinite,
                  candidate.weightLbs >= 40,
                  candidate.weightLbs <= 1_200 else {
                result.skipped += 1
                continue
            }

            if let nomvaEntryID = candidate.nomvaEntryID,
               let existing = entries.first(where: { $0.id == nomvaEntryID }) {
                existing.externalIdentifier = candidate.externalIdentifier
                result.skipped += 1
                continue
            }

            let snapshots = entries.map {
                (externalIdentifier: $0.externalIdentifier, date: $0.date, weightLbs: $0.weightLbs)
            }
            if let duplicateIndex = WeightImportPlanner.duplicateIndex(for: candidate, in: snapshots) {
                let existing = entries[duplicateIndex]
                if existing.externalIdentifier == candidate.externalIdentifier,
                   (abs(existing.weightLbs - candidate.weightLbs) > 0.001 || existing.date != candidate.date) {
                    existing.weightLbs = candidate.weightLbs
                    existing.date = candidate.date
                    existing.sourceName = candidate.sourceName
                    result.updated += 1
                } else {
                    result.skipped += 1
                }
                continue
            }

            let entry = WeightEntry(
                date: candidate.date,
                weightLbs: candidate.weightLbs,
                source: candidate.source,
                sourceName: candidate.sourceName,
                externalIdentifier: candidate.externalIdentifier
            )
            modelContext.insert(entry)
            entries.append(entry)
            result.inserted += 1
        }

        if result.imported > 0 || candidates.contains(where: { $0.nomvaEntryID != nil }) {
            try modelContext.save()
        }
        return result
    }
}
