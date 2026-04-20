import Foundation
import HealthKit

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

enum AppleHealthServiceError: LocalizedError {
    case unavailable
    case unsupportedDataType

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Health is not available on this device."
        case .unsupportedDataType:
            return "Active calorie data is not supported on this device."
        }
    }
}

enum AppleHealthService {
    private static let healthStore = HKHealthStore()

    private static var activeEnergyType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
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
