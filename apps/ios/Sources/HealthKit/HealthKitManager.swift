import Foundation
import HealthKit

final class HealthKitManager: Sendable {
    private let store = HKHealthStore()

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthKit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HEALTHKIT_UNAVAILABLE: HealthKit not available on this device",
            ])
        }

        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKCategoryType(.sleepAnalysis),
        ]

        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: - Heart Rate

    func heartRate(startISO: String? = nil, endISO: String? = nil, limit: Int? = nil) async throws -> [[String: Any]] {
        let type = HKQuantityType(.heartRate)
        let (start, end) = Self.resolveRange(startISO: startISO, endISO: endISO)
        let sampleLimit = Self.clampLimit(limit, default: 100)

        let samples = try await querySamples(
            type: type, start: start, end: end, limit: sampleLimit)

        let formatter = ISO8601DateFormatter()
        return samples.compactMap { sample -> [String: Any]? in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return [
                "dateISO": formatter.string(from: quantity.startDate),
                "bpm": quantity.quantity.doubleValue(for: .count().unitDivided(by: .minute())),
            ]
        }
    }

    // MARK: - Steps

    func steps(startISO: String? = nil, endISO: String? = nil) async throws -> [String: Any] {
        let type = HKQuantityType(.stepCount)
        let (start, end) = Self.resolveRange(startISO: startISO, endISO: endISO)

        let count = try await statisticsSum(type: type, start: start, end: end, unit: .count())

        let formatter = ISO8601DateFormatter()
        return [
            "startISO": formatter.string(from: start),
            "endISO": formatter.string(from: end),
            "steps": count,
        ]
    }

    // MARK: - Sleep

    func sleep(startISO: String? = nil, endISO: String? = nil, limit: Int? = nil) async throws -> [[String: Any]] {
        let type = HKCategoryType(.sleepAnalysis)
        let (start, end) = Self.resolveRange(startISO: startISO, endISO: endISO)
        let sampleLimit = Self.clampLimit(limit, default: 100)

        let samples = try await querySamples(
            type: type, start: start, end: end, limit: sampleLimit)

        let formatter = ISO8601DateFormatter()
        return samples.compactMap { sample -> [String: Any]? in
            guard let category = sample as? HKCategorySample else { return nil }
            return [
                "startISO": formatter.string(from: category.startDate),
                "endISO": formatter.string(from: category.endDate),
                "stage": Self.sleepStageString(category.value),
            ]
        }
    }

    // MARK: - Activity (Energy + Exercise Time)

    func activity(startISO: String? = nil, endISO: String? = nil) async throws -> [String: Any] {
        let (start, end) = Self.resolveRange(startISO: startISO, endISO: endISO)

        let energyType = HKQuantityType(.activeEnergyBurned)
        let exerciseType = HKQuantityType(.appleExerciseTime)

        async let energy = statisticsSum(type: energyType, start: start, end: end, unit: .kilocalorie())
        async let exercise = statisticsSum(type: exerciseType, start: start, end: end, unit: .minute())

        let formatter = ISO8601DateFormatter()
        return [
            "startISO": formatter.string(from: start),
            "endISO": formatter.string(from: end),
            "activeEnergyKcal": try await energy,
            "exerciseMinutes": try await exercise,
        ]
    }

    // MARK: - Private Helpers

    private func querySamples(
        type: HKSampleType, start: Date, end: Date, limit: Int
    ) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate,
                limit: limit, sortDescriptors: [sort]
            ) { _, results, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: results ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func statisticsSum(
        type: HKQuantityType, start: Date, end: Date, unit: HKUnit
    ) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    let value = stats?.sumQuantity()?.doubleValue(for: unit) ?? 0
                    cont.resume(returning: value)
                }
            }
            store.execute(query)
        }
    }

    private static func resolveRange(startISO: String?, endISO: String?) -> (Date, Date) {
        let formatter = ISO8601DateFormatter()
        let start = startISO.flatMap { formatter.date(from: $0) } ?? Calendar.current.startOfDay(for: Date())
        let end = endISO.flatMap { formatter.date(from: $0) } ?? Date()
        return (start, end)
    }

    private static func clampLimit(_ limit: Int?, default defaultLimit: Int) -> Int {
        max(1, min(limit ?? defaultLimit, 1000))
    }

    private static func sleepStageString(_ value: Int) -> String {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: value) else { return "unknown" }
        switch stage {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleep"
        case .awake: return "awake"
        case .asleepCore: return "core"
        case .asleepDeep: return "deep"
        case .asleepREM: return "rem"
        @unknown default: return "unknown"
        }
    }
}
