import Foundation
import HealthKit
import SwiftData
import Combine

/// HealthKit's legacy acknowledgement block is not annotated Sendable. Give it
/// one synchronized owner and acknowledge only after the anchored import finishes.
private final class HealthObserverAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (() -> Void)?
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func complete() {
        lock.lock()
        let action = callback
        callback = nil
        lock.unlock()
        action?()
    }
}

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
    var syncVersion: Int? = nil
}

struct AppleHealthWeightChangePage: Sendable {
    let samples: [AppleHealthWeightSample]
    let deletedIdentifiers: [String]
    let anchor: Data?
    let changeCount: Int
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
    var syncVersion: Int? = nil
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
    case stalledHistory

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Health is not available on this device."
        case .unsupportedDataType:
            return "The requested Apple Health data is not supported on this device."
        case .weightPermissionDenied:
            return "Nomva does not have permission to save weight in Apple Health."
        case .stalledHistory:
            return "Apple Health history could not advance. Try Recheck All Health History in Weight Sync. Your saved weights are unchanged."
        }
    }
}

enum AppleHealthService {
    private static let healthStore = HKHealthStore()
    private static let nomvaEntryMetadataKey = "com.nomva.weight.entry-id"
    @MainActor private static var weightObserver: HKObserverQuery?
    @MainActor private static var activityObserver: HKObserverQuery?

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

    static func fetchWeightChanges(anchorData: Data?) async throws -> AppleHealthWeightChangePage {
        guard isAvailable(), let bodyMassType else { throw AppleHealthServiceError.unavailable }
        let anchor = try anchorData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: bodyMassType, predicate: nil, anchor: anchor, limit: 500) { _, samples, deleted, nextAnchor, error in
                if let error { continuation.resume(throwing: error); return }
                do {
                    let mapped = (samples as? [HKQuantitySample] ?? []).compactMap { sample -> AppleHealthWeightSample? in
                        let pounds = sample.quantity.doubleValue(for: .pound())
                        guard pounds.isFinite, (40...1_200).contains(pounds) else { return nil }
                        let isOwn = sample.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier
                        let entryID = isOwn ? (sample.metadata?[nomvaEntryMetadataKey] as? String).flatMap(UUID.init(uuidString:)) : nil
                        return AppleHealthWeightSample(externalIdentifier: "apple:\(sample.uuid.uuidString.lowercased())", date: sample.startDate,
                            weightLbs: pounds, sourceName: sample.sourceRevision.source.name, nomvaEntryID: entryID,
                            syncVersion: (sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue)
                    }
                    let archived = try nextAnchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                    continuation.resume(returning: AppleHealthWeightChangePage(
                        samples: mapped, deletedIdentifiers: (deleted ?? []).map { "apple:\($0.uuid.uuidString.lowercased())" },
                        anchor: archived, changeCount: (samples?.count ?? 0) + (deleted?.count ?? 0)))
                } catch { continuation.resume(throwing: error) }
            }
            healthStore.execute(query)
        }
    }

    @MainActor
    static func startWeightObservation(onChange: @escaping @Sendable () async -> Void) async {
        guard WeightSyncPreferences.appleHealthImportEnabled else {
            if let observer = weightObserver {
                healthStore.stop(observer)
                weightObserver = nil
                if let bodyMassType { try? await healthStore.disableBackgroundDelivery(for: bodyMassType) }
            }
            return
        }
        guard weightObserver == nil, isAvailable(), let bodyMassType,
              WeightSyncPreferences.appleHealthImportEnabled else { return }
        let observer = HKObserverQuery(sampleType: bodyMassType, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            let acknowledgement = HealthObserverAcknowledgement(completion)
            Task { await onChange(); acknowledgement.complete() }
        }
        weightObserver = observer
        healthStore.execute(observer)
        do { try await healthStore.enableBackgroundDelivery(for: bodyMassType, frequency: .immediate) }
        catch { WeightSyncPreferences.record(error: error) }
    }

    static func deleteNomvaWeight(entryID: UUID) async throws {
        guard isAvailable(), let bodyMassType else { throw AppleHealthServiceError.unavailable }
        guard weightWriteAuthorizationStatus() == .sharingAuthorized else { throw AppleHealthServiceError.weightPermissionDenied }
        let ownSource = HKQuery.predicateForObjects(from: HKSource.default())
        let identity = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                                  allowedValues: ["com.nomva.weight.\(entryID.uuidString.lowercased())"])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.deleteObjects(of: bodyMassType, predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [ownSource, identity])) { success, _, error in
                if let error { continuation.resume(throwing: error) }
                else if !success { continuation.resume(throwing: AppleHealthServiceError.weightPermissionDenied) }
                else { continuation.resume() }
            }
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
        try await fetchActivitySnapshot(windowDays: windowDays).completedSummary()
    }

    static func fetchActivitySnapshot(windowDays: Int = 28, now: Date = .now,
                                      calendar: Calendar = .current) async throws -> HealthActivitySnapshot {
        guard isAvailable(), let activeEnergyType else { throw AppleHealthServiceError.unavailable }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -windowDays, to: today)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: activeEnergyType,
                quantitySamplePredicate: predicate, options: .cumulativeSum,
                anchorDate: today, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var days: [HealthActivityDay] = []
                collection?.enumerateStatistics(from: start, to: now) { statistics, _ in
                    guard let value = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()),
                          value.isFinite, value >= 0 else { return }
                    days.append(HealthActivityDay(date: statistics.startDate, activeCalories: value))
                }
                continuation.resume(returning: HealthActivitySnapshot(days: days, checkedAt: now, windowDays: windowDays))
            }
            healthStore.execute(query)
        }
    }

    @MainActor
    static func observeActivity(enabled: Bool, onChange: @escaping @Sendable () async -> Void) async {
        guard enabled else {
            if let observer = activityObserver {
                healthStore.stop(observer)
                activityObserver = nil
                if let activeEnergyType { try? await healthStore.disableBackgroundDelivery(for: activeEnergyType) }
            }
            return
        }
        guard activityObserver == nil, isAvailable(), let activeEnergyType else { return }
        let observer = HKObserverQuery(sampleType: activeEnergyType, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            let acknowledgement = HealthObserverAcknowledgement(completion)
            Task { await onChange(); acknowledgement.complete() }
        }
        activityObserver = observer
        healthStore.execute(observer)
        do { try await healthStore.enableBackgroundDelivery(for: activeEnergyType, frequency: .immediate) }
        catch { AppleHealthActivityManager.shared.lastError = error.localizedDescription }
    }
}

struct HealthActivityDay: Equatable, Sendable {
    var date: Date
    var activeCalories: Double
}

struct HealthActivitySnapshot: Equatable, Sendable {
    var days: [HealthActivityDay]
    var checkedAt: Date
    var windowDays: Int

    func calories(on date: Date, calendar: Calendar = .current) -> Double? {
        days.first { calendar.isDate($0.date, inSameDayAs: date) }?.activeCalories
    }

    func completedSummary(calendar: Calendar = .current) -> AppleHealthActivitySummary? {
        let end = calendar.startOfDay(for: checkedAt)
        let start = calendar.date(byAdding: .day, value: -windowDays, to: end)!
        let completed = days.filter { $0.date >= start && $0.date < end && $0.activeCalories.isFinite && $0.activeCalories >= 0 }
        guard !completed.isEmpty else { return nil }
        return AppleHealthActivitySummary(averageActiveCalories: completed.reduce(0) { $0 + $1.activeCalories } / Double(completed.count),
            sampledDays: completed.count, windowDays: windowDays, startDate: start, endDate: end)
    }
}

@MainActor
final class AppleHealthActivityManager: ObservableObject {
    static let shared = AppleHealthActivityManager()
    private let refreshGate = NomvaCloudAttestedRequestGate()
    @Published private(set) var snapshot: HealthActivitySnapshot?
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?

    var averageActiveCalories: Double? { snapshot?.completedSummary()?.averageActiveCalories }
    func calories(on date: Date) -> Double? { snapshot?.calories(on: date) }

    func refresh(fetch: @escaping @Sendable () async throws -> HealthActivitySnapshot = { try await AppleHealthService.fetchActivitySnapshot() }) async {
        do {
            try await refreshGate.withExclusiveAccess { @MainActor in
                self.isRefreshing = true
                defer { self.isRefreshing = false }
                do {
                    self.snapshot = try await fetch()
                    self.lastError = nil
                } catch { self.lastError = error.localizedDescription }
            }
        } catch is CancellationError {} catch { lastError = error.localizedDescription }
    }

    func startAndRefresh(enabled: Bool) async {
        guard !NomvaRuntime.isAutomatedTest else { return }
        await AppleHealthService.observeActivity(enabled: enabled) { @MainActor in
            await AppleHealthActivityManager.shared.refresh()
        }
        if enabled { await refresh() }
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

@MainActor
enum WeightSyncCoordinator {
    private static let gate = NomvaCloudAttestedRequestGate()
    private static let cycleGate = NomvaCloudAttestedRequestGate()
    private static var deletionWake: Task<Void, Never>?

    static func importAppleHealth(into modelContext: ModelContext, client: WeightHealthClient = .live, recheckHistory: Bool = false) async throws -> WeightImportResult {
        try await gate.withExclusiveAccess { @MainActor in
            let state = try modelContext.fetch(FetchDescriptor<WeightSyncState>()).first ?? WeightSyncState()
            if state.modelContext == nil { modelContext.insert(state) }
            var total = WeightImportResult()
            var nextAnchor = recheckHistory ? nil : state.anchor
            while true {
                try Task.checkCancellation()
                let page = try await client.fetchChanges(nextAnchor)
                try Task.checkCancellation()
                guard page.changeCount < 500 || (page.anchor != nil && page.anchor != nextAnchor) else {
                    throw AppleHealthServiceError.stalledHistory
                }
                // Keep edits made in the UI during the read if importing this page fails.
                try modelContext.save()
                do {
                    let candidates = page.samples.map {
                        WeightImportCandidate(source: .appleHealth, externalIdentifier: $0.externalIdentifier,
                            date: $0.date, weightLbs: $0.weightLbs, sourceName: $0.sourceName, nomvaEntryID: $0.nomvaEntryID, syncVersion: $0.syncVersion)
                    }
                    let result = try apply(candidates, to: modelContext, save: false)
                    try applyHealthDeletions(page.deletedIdentifiers, to: modelContext)
                    state.anchor = page.anchor
                    nextAnchor = page.anchor
                    state.lastReadAt = .now
                    if let latest = page.samples.max(by: { $0.date < $1.date }), latest.date >= (state.lastSampleAt ?? .distantPast) {
                        state.lastSampleAt = latest.date
                        state.lastSourceName = latest.sourceName
                    }
                    try modelContext.save()
                    total.inserted += result.inserted
                    total.updated += result.updated
                    total.skipped += result.skipped
                } catch {
                    modelContext.rollback()
                    throw error
                }
                if page.changeCount < 500 { break }
            }
            return total
        }
    }

    static func exportToAppleHealth(_ entry: WeightEntry, in modelContext: ModelContext, client: WeightHealthClient = .live) async throws {
        _ = try await exportAllNomvaWeightsToAppleHealth(from: [entry], in: modelContext, client: client)
    }

    @discardableResult
    static func exportAllNomvaWeightsToAppleHealth(
        from entries: [WeightEntry], in modelContext: ModelContext,
        client: WeightHealthClient = .live, enabled: Bool = WeightSyncPreferences.appleHealthExportEnabled
    ) async throws -> Int {
        guard enabled else { return 0 }
        return try await gate.withExclusiveAccess { @MainActor in
            var exported = 0
            let exportable = entries.filter { $0.modelContext != nil && !$0.isDeleted && $0.dataSource == .nomva && $0.healthExportedFingerprint != $0.healthFingerprint }
            for start in stride(from: 0, to: exportable.count, by: 100) {
                try Task.checkCancellation()
                // The user can edit/delete later chunks while an earlier Health write is suspended.
                let chunk = Array(exportable[start..<min(start + 100, exportable.count)]).filter { $0.modelContext != nil && !$0.isDeleted }
                guard !chunk.isEmpty else { continue }
                let writes = chunk.map { entry -> AppleHealthWeightWrite in
                    if entry.healthPendingFingerprint != entry.healthFingerprint {
                        entry.healthSyncVersion = nextHealthSyncVersion(after: entry.healthSyncVersion ?? 0)
                        entry.healthPendingFingerprint = entry.healthFingerprint
                    }
                    return AppleHealthWeightWrite(entryID: entry.id, date: entry.date, weightLbs: entry.weightLbs, syncVersion: entry.healthSyncVersion ?? 1)
                }
                let fingerprints = chunk.map(\.healthFingerprint)
                // Persist the same version before writing: a retry after process death is idempotent.
                try modelContext.save()
                _ = try await client.save(writes)
                for (index, entry) in chunk.enumerated() where entry.modelContext != nil && !entry.isDeleted {
                    entry.healthExportedFingerprint = fingerprints[index]
                    if entry.healthPendingFingerprint == fingerprints[index] { entry.healthPendingFingerprint = nil }
                    // HealthKit may ignore a replayed version; its generated UUID is not proof of storage.
                    // The anchored reader binds the actual UUID using our entry-id metadata.
                    exported += 1
                }
                try modelContext.save()
            }
            return exported
        }
    }

    static func queueDeletion(_ entry: WeightEntry, in modelContext: ModelContext) {
        modelContext.insert(WeightSyncTombstone(entry: entry))
        modelContext.delete(entry)
        deletionWake?.cancel()
        let container = modelContext.container
        deletionWake = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(16)) } catch { return }
            await syncEnabledSources(in: ModelContext(container))
        }
    }

    static func nextHealthSyncVersion(after previous: Int, now: Date = .now) -> Int {
        // Clock-based revisions avoid restarting at 1 on a second device. The
        // persisted previous value also keeps retries monotonic after clock changes.
        max(previous + 1, Int(now.timeIntervalSince1970 * 1_000_000))
    }

    static func flushDeletions(in modelContext: ModelContext, client: WeightHealthClient = .live,
                               enabled: Bool = WeightSyncPreferences.appleHealthExportEnabled, now: Date = .now) async throws {
        try await gate.withExclusiveAccess { @MainActor in
            let entries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for tombstone in try modelContext.fetch(FetchDescriptor<WeightSyncTombstone>()) {
                if let restored = byID[tombstone.entryID] {
                    // Undo after an external deletion must re-export the restored entry.
                    if !tombstone.pending && tombstone.deleteFromHealth { restored.healthExportedFingerprint = nil }
                    modelContext.delete(tombstone)
                } else if enabled && tombstone.pending && tombstone.deleteFromHealth && tombstone.notBefore <= now {
                    try await client.delete(tombstone.entryID)
                    tombstone.pending = false
                }
                try modelContext.save()
            }
        }
    }

    static func syncEnabledSources(in modelContext: ModelContext) async {
        guard !NomvaRuntime.isAutomatedTest else { return }
        let report = await synchronize(in: modelContext)
        UserDefaults.standard.set(report.errors.joined(separator: "\n"), forKey: WeightSyncPreferences.lastErrorKey)
    }

    /// A failure in one direction must not strand work in the other. All callers
    /// use the same cycle, and successful pages/writes remain durable on partial failure.
    static func synchronize(in context: ModelContext, client: WeightHealthClient = .live,
                            importEnabled: Bool = WeightSyncPreferences.appleHealthImportEnabled,
                            exportEnabled: Bool = WeightSyncPreferences.appleHealthExportEnabled,
                            recheckHistory: Bool = false) async -> WeightSyncReport {
        do {
            return try await cycleGate.withExclusiveAccess { @MainActor in
                var report = WeightSyncReport()
                if importEnabled {
                    do { report.imported = try await importAppleHealth(into: context, client: client, recheckHistory: recheckHistory) }
                    catch { report.errors.append("Read: \(error.localizedDescription)") }
                }
                try Task.checkCancellation()
                do { try await flushDeletions(in: context, client: client, enabled: exportEnabled) }
                catch { report.errors.append("Delete: \(error.localizedDescription)") }
                try Task.checkCancellation()
                if exportEnabled {
                    do {
                        report.exported = try await exportAllNomvaWeightsToAppleHealth(
                            from: context.fetch(FetchDescriptor<WeightEntry>()), in: context, client: client, enabled: true)
                    } catch { report.errors.append("Save: \(error.localizedDescription)") }
                }
                return report
            }
        } catch { return WeightSyncReport(errors: [error.localizedDescription]) }
    }

    private static func applyHealthDeletions(_ identifiers: [String], to context: ModelContext) throws {
        guard !identifiers.isEmpty else { return }
        let deleted = Set(identifiers)
        for entry in try context.fetch(FetchDescriptor<WeightEntry>()) {
            let isCleanNomvaCopy = entry.dataSource == .nomva && entry.healthExportedFingerprint == entry.healthFingerprint && entry.healthPendingFingerprint == nil
            if (entry.dataSource == .appleHealth || isCleanNomvaCopy), let primary = entry.externalIdentifier, deleted.contains(primary) {
                let tombstone = WeightSyncTombstone(entry: entry)
                tombstone.deleteFromHealth = false
                tombstone.pending = false
                context.insert(tombstone)
                context.delete(entry)
            } else {
                entry.externalAliases = Array(entry.allExternalIdentifiers.subtracting(deleted))
                if let primary = entry.externalIdentifier, deleted.contains(primary) {
                    entry.externalIdentifier = nil
                    // A local edit made before seeing the deletion remains queued.
                    if entry.dataSource == .nomva { entry.healthPendingFingerprint = nil }
                }
            }
        }
    }

    static func apply(_ candidates: [WeightImportCandidate], to modelContext: ModelContext, save: Bool = true) throws -> WeightImportResult {
        var entries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
        let tombstones = try modelContext.fetch(FetchDescriptor<WeightSyncTombstone>())
        let suppressed = Set(tombstones.flatMap(\.externalIdentifiers))
        // Source deletions suppress only that sample UUID. A replacement can
        // arrive on a later anchored page; only a user deletion suppresses its entry ID.
        let deletedOwnIDs = Set(tombstones.filter(\.deleteFromHealth).map(\.entryID))
        var byExternalID: [String: WeightEntry] = [:]
        var byID: [UUID: WeightEntry] = [:]
        for entry in entries {
            byID[entry.id] = entry
            for alias in entry.allExternalIdentifiers { byExternalID[alias] = entry }
        }
        var result = WeightImportResult()
        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            guard candidate.weightLbs.isFinite, (40...1_200).contains(candidate.weightLbs),
                  !suppressed.contains(candidate.externalIdentifier),
                  candidate.nomvaEntryID.map({ !deletedOwnIDs.contains($0) }) ?? true else {
                result.skipped += 1; continue
            }
            if let ownID = candidate.nomvaEntryID, let existing = byID[ownID] {
                existing.externalAliases = Array(existing.allExternalIdentifiers.union([candidate.externalIdentifier]))
                byExternalID[candidate.externalIdentifier] = existing
                let version = candidate.syncVersion ?? 0
                let previous = existing.healthSyncVersion ?? 0
                guard version >= previous else { result.skipped += 1; continue }
                existing.externalIdentifier = candidate.externalIdentifier
                existing.healthSyncVersion = max(previous, version)
                let matchesLocal = abs(existing.weightLbs - candidate.weightLbs) < 0.000_001 && abs(existing.date.timeIntervalSince(candidate.date)) < 0.000_001
                let legacyExport = existing.healthExportedFingerprint == nil && existing.healthPendingFingerprint == nil && previous > 0
                let hasLocalEdit = !legacyExport && (existing.healthExportedFingerprint != existing.healthFingerprint || existing.healthPendingFingerprint != nil)
                if matchesLocal || !hasLocalEdit {
                    let changed = !matchesLocal
                    existing.weightLbs = candidate.weightLbs
                    existing.date = candidate.date
                    existing.healthExportedFingerprint = existing.healthFingerprint
                    existing.healthPendingFingerprint = nil
                    if changed { result.updated += 1 } else { result.skipped += 1 }
                } else {
                    // An unsent local edit survives a remote update. Issue a new
                    // revision above the observed remote version on the next export.
                    if version > previous { existing.healthPendingFingerprint = nil }
                    result.skipped += 1
                }
                continue
            }
            // Only reconcile the known Garmin-to-Health bridge. Distinct Health samples stay distinct.
            let bridge = entries.first {
                let knownBridge = ($0.dataSource == .garmin && candidate.source == .appleHealth && candidate.sourceName.lowercased().contains("garmin")) ||
                    ($0.dataSource == .appleHealth && $0.resolvedSourceName.lowercased().contains("garmin") && candidate.source == .garmin)
                return knownBridge && abs($0.date.timeIntervalSince(candidate.date)) <= 1 && abs($0.weightLbs - candidate.weightLbs) <= 0.01
            }
            if let existing = byExternalID[candidate.externalIdentifier] ?? bridge {
                existing.externalAliases = Array(existing.allExternalIdentifiers.union([candidate.externalIdentifier]))
                byExternalID[candidate.externalIdentifier] = existing
                if existing.dataSource == .nomva {
                    result.skipped += 1
                    continue
                }
                if candidate.source == .appleHealth || existing.dataSource == candidate.source {
                    let changed = existing.weightLbs != candidate.weightLbs || existing.date != candidate.date || existing.dataSource != candidate.source
                    existing.weightLbs = candidate.weightLbs
                    existing.date = candidate.date
                    existing.sourceRaw = candidate.source.rawValue
                    existing.sourceName = candidate.sourceName
                    existing.externalIdentifier = candidate.externalIdentifier
                    if changed { result.updated += 1 } else { result.skipped += 1 }
                } else { result.skipped += 1 }
                continue
            }
            let entry = WeightEntry(date: candidate.date, weightLbs: candidate.weightLbs,
                                    source: candidate.nomvaEntryID == nil ? candidate.source : .nomva,
                                    sourceName: candidate.sourceName, externalIdentifier: candidate.externalIdentifier)
            if let ownID = candidate.nomvaEntryID {
                entry.id = ownID
                entry.healthSyncVersion = candidate.syncVersion
                entry.healthExportedFingerprint = entry.healthFingerprint
                // Health replacement pages may separate delete from add. Preserve
                // the note locally without putting that note in Health metadata.
                entry.note = tombstones.last { $0.entryID == ownID && !$0.deleteFromHealth }?.localNote
            }
            modelContext.insert(entry)
            entries.append(entry)
            byID[entry.id] = entry
            byExternalID[candidate.externalIdentifier] = entry
            result.inserted += 1
        }
        if save { try modelContext.save() }
        return result
    }
}

struct WeightSyncReport: Sendable {
    var imported = WeightImportResult()
    var exported = 0
    var errors: [String] = []

    var summary: String {
        "\(imported.inserted) added, \(imported.updated) updated, \(exported) saved to Apple Health."
    }
}

struct WeightHealthClient: Sendable {
    var fetchChanges: @Sendable (Data?) async throws -> AppleHealthWeightChangePage
    var save: @Sendable ([AppleHealthWeightWrite]) async throws -> [UUID: String]
    var delete: @Sendable (UUID) async throws -> Void

    static let live = WeightHealthClient(
        fetchChanges: { try await AppleHealthService.fetchWeightChanges(anchorData: $0) },
        save: { try await AppleHealthService.saveWeights($0) },
        delete: { try await AppleHealthService.deleteNomvaWeight(entryID: $0) }
    )
}
