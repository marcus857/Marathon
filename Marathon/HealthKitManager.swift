//
//  HealthKitManager.swift
//  Marathon
//
//  Created by Marcus Price on 11/11/25.
//

import Foundation
import HealthKit
import CoreLocation

struct RunSummary: Identifiable, Hashable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let distanceMiles: Double
    let paceMinutesPerMile: Double
    let sourceName: String
    let sourceBundleIdentifier: String

    // For deep linking / mapping
    let workoutUUID: UUID?
    let externalId: String? // e.g., Strava activity id when available
}

enum HealthKitManagerError: Error {
    case healthDataUnavailable
    case dataTypeUnavailable
    case authorizationFailed
}

// MARK: - Heart Rate Zones

struct ZoneBreakdown: Hashable, Codable, Sendable {
    // durations in seconds for zones Z1...Z5
    var durations: [TimeInterval] // count == 5
    var total: TimeInterval

    nonisolated init(durations: [TimeInterval] = Array(repeating: 0, count: 5), total: TimeInterval = 0) {
        self.durations = durations
        self.total = total
    }

    var percentages: [Double] {
        guard total > 0 else { return Array(repeating: 0, count: durations.count) }
        return durations.map { min(1.0, max(0.0, $0 / total)) }
    }
}

// HRR-based zone assignment (configurable 5 zones)
private enum HRZones {
    static func index(for bpm: Double, maxHR: Double, restingHR: Double, config: HRZoneConfig) -> Int {
        guard maxHR > 0, bpm > 0 else { return 0 }
        let reserve = max(1.0, maxHR - restingHR)
        let pct = (bpm - restingHR) / reserve
        return config.zoneIndex(forHRR: pct)
    }
}

actor HRBreakdownCache {
    private var map: [String: ZoneBreakdown] = [:]
    fileprivate func get(_ key: String) -> ZoneBreakdown? { map[key] }
    fileprivate func set(_ key: String, value: ZoneBreakdown) { map[key] = value }
}

final class HealthKitManager {
    static let shared = HealthKitManager()
    private let healthStore = HKHealthStore()
    private init() {}

    private let hrCache = HRBreakdownCache()
    private var cachedMaxHR: Int?
    private var cachedRestingHR: Int?

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // Request read authorization for workouts, walking/running distance, VO2max, heart rate, RESTING heart rate,
    // date of birth (for Max HR estimate), and workout routes
    func requestAuthorization() async throws {
        guard isHealthDataAvailable else {
            throw HealthKitManagerError.healthDataUnavailable
        }

        let workoutType = HKObjectType.workoutType()
        guard let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) else {
            throw HealthKitManagerError.dataTypeUnavailable
        }
        let vo2Type = HKObjectType.quantityType(forIdentifier: .vo2Max)
        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)
        let rhrType = HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        let dobType = HKObjectType.characteristicType(forIdentifier: .dateOfBirth)
        let routeType = HKSeriesType.workoutRoute()

        var readTypes: Set<HKObjectType> = [workoutType, distanceType, routeType]
        if let vo2Type { readTypes.insert(vo2Type) }
        if let hrType { readTypes.insert(hrType) }
        if let rhrType { readTypes.insert(rhrType) }
        if let dobType { readTypes.insert(dobType) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitManagerError.authorizationFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - General runs (arbitrary date interval)

    // Fetch running and walking workouts in the provided interval, filter by duration and pace, deduplicate overlapping
    // entries (e.g., Strava + Apple duplicates), and return sorted ascending by start date.
    func fetchRuns(in interval: DateInterval,
                   minDurationMinutes: Double = 15.0,
                   maxPaceMinutesPerMile: Double = 15.0) async throws -> [RunSummary] {

        guard interval.duration > 0 else { return [] }

        let datePredicate = HKQuery.predicateForSamples(withStart: interval.start,
                                                        end: interval.end,
                                                        options: .strictStartDate)
        let runningPredicate = HKQuery.predicateForWorkouts(with: .running)
        let walkingPredicate = HKQuery.predicateForWorkouts(with: .walking)
        let activityPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [runningPredicate, walkingPredicate])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, activityPredicate])

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            self.healthStore.execute(query)
        }

        let mileUnit = HKUnit.mile()
        let minDurationSeconds = minDurationMinutes * 60.0

        let filteredSummaries: [RunSummary] = workouts.compactMap { w in
            let duration = w.duration
            guard duration >= minDurationSeconds else { return nil }
            guard let totalDistance = w.totalDistance else { return nil }
            let distanceMiles = totalDistance.doubleValue(for: mileUnit)
            guard distanceMiles > 0 else { return nil }

            let paceMinPerMile = (duration / 60.0) / distanceMiles
            guard paceMinPerMile <= maxPaceMinutesPerMile else { return nil }

            let sr = w.sourceRevision
            let sourceLabel = sourceNameLabel(forAppName: sr.source.name, bundleID: sr.source.bundleIdentifier)
            let isStrava = sr.source.bundleIdentifier.lowercased().contains("com.strava") || sourceLabel.lowercased().contains("strava")

            var externalId: String? = nil
            if isStrava, let md = w.metadata {
                externalId = stravaActivityId(from: md)
            }

            return RunSummary(
                startDate: w.startDate,
                endDate: w.endDate,
                duration: duration,
                distanceMiles: distanceMiles,
                paceMinutesPerMile: paceMinPerMile,
                sourceName: sourceLabel,
                sourceBundleIdentifier: sr.source.bundleIdentifier,
                workoutUUID: w.uuid,
                externalId: externalId
            )
        }

        let deduped = deduplicateByOverlapLongestDuration(filteredSummaries, overlapThreshold: 60)
        return deduped.sorted(by: { $0.startDate < $1.startDate })
    }

    // Extract Strava activity id from metadata (best effort).
    private func stravaActivityId(from metadata: [String: Any]) -> String? {
        let preferredKeys: [String] = [
            HKMetadataKeyExternalUUID,
            HKMetadataKeySyncIdentifier,
            "com.strava.activityId",
            "StravaActivityId",
            "strava_activity_id"
        ]

        for key in preferredKeys {
            if let v = metadata[key] {
                if let s = v as? String {
                    if isLikelyStravaId(s) { return s }
                    if let digits = extractDigits(s), isLikelyStravaId(digits) { return digits }
                } else if let n = v as? NSNumber {
                    return n.stringValue
                }
            }
        }

        for v in metadata.values {
            if let s = v as? String, let digits = extractDigits(s), isLikelyStravaId(digits) {
                return digits
            }
        }
        return nil
    }

    private func extractDigits(_ s: String) -> String? {
        let digits = s.filter { $0.isNumber }
        return digits.isEmpty ? nil : digits
    }

    private func isLikelyStravaId(_ s: String) -> Bool {
        let len = s.count
        return len >= 6 && len <= 20 && s.allSatisfy({ $0.isNumber })
    }

    // MARK: - VO2max

    func fetchVO2MaxByWeek(since startDate: Date? = nil) async throws -> [Date: Double] {
        guard let vo2Type = HKObjectType.quantityType(forIdentifier: .vo2Max) else {
            return [:]
        }

        let cal = Calendar.current
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: Date()) ?? Date.distantPast
        let defaultStart = mondayOfWeek(for: oneYearAgo)
        let start = startDate.map { mondayOfWeek(for: $0) } ?? defaultStart

        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(sampleType: vo2Type,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            self.healthStore.execute(query)
        }

        let ml = HKUnit.literUnit(with: .milli)
        let kg = HKUnit.gramUnit(with: .kilo)
        let min = HKUnit.minute()
        let unit = ml.unitDivided(by: kg).unitDivided(by: min)

        var byWeekLatest: [Date: (value: Double, date: Date)] = [:]
        for s in samples {
            let value = s.quantity.doubleValue(for: unit)
            let monday = mondayOfWeek(for: s.startDate)
            if let existing = byWeekLatest[monday] {
                if s.startDate > existing.date {
                    byWeekLatest[monday] = (value, s.startDate)
                }
            } else {
                byWeekLatest[monday] = (value, s.startDate)
            }
        }

        var result: [Date: Double] = [:]
        for (k, v) in byWeekLatest {
            result[k] = v.value
        }
        return result
    }

    // MARK: - Heart Rate APIs

    func fetchHeartRateSamples(in interval: DateInterval) async throws -> [HKQuantitySample] {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitManagerError.dataTypeUnavailable
        }

        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(sampleType: hrType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            self.healthStore.execute(query)
        }
    }

    // Latest Resting Heart Rate (bpm), if available
    func fetchLatestRestingHeartRate() async throws -> Double? {
        guard let rhrType = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
            return nil
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let q = HKSampleQuery(sampleType: rhrType,
                                  predicate: nil,
                                  limit: 1,
                                  sortDescriptors: [sort]) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            self.healthStore.execute(q)
        }
        guard let s = samples.first else { return nil }
        let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        return s.quantity.doubleValue(for: bpmUnit)
    }

    // Estimated Resting HR (bpm): cached if available, otherwise latest sample or 60 bpm fallback
    func estimateRestingHR() async -> Int {
        if let cached = cachedRestingHR { return cached }
        if let v = try? await fetchLatestRestingHeartRate() {
            let rr = max(30, min(100, Int(v.rounded())))
            cachedRestingHR = rr
            return rr
        }
        cachedRestingHR = 60
        return 60
    }

    // Average HR over a specific interval (fallback method)
    func averageHR(in interval: DateInterval) async throws -> Double? {
        let samples = try await fetchHeartRateSamples(in: interval)
        guard !samples.isEmpty else { return nil }
        let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let values = samples.map { $0.quantity.doubleValue(for: bpmUnit) }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return avg
    }

    // Average HR for a specific workout using predicateForObjects(from: workout), with interval fallback
    func averageHR(forWorkoutUUID uuid: UUID, start: Date? = nil, end: Date? = nil) async throws -> Double? {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitManagerError.dataTypeUnavailable
        }
        guard let workout = try await fetchWorkout(by: uuid) else {
            if let s = start, let e = end {
                return try await averageHR(in: DateInterval(start: s, end: e))
            }
            return nil
        }

        // Try statistics average first (fast path)
        let predicate = HKQuery.predicateForObjects(from: workout)
        let avg: Double? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
            let q = HKStatisticsQuery(quantityType: hrType,
                                      quantitySamplePredicate: predicate,
                                      options: .discreteAverage) { _, stats, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let q = stats?.averageQuantity() {
                    let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
                    continuation.resume(returning: q.doubleValue(for: bpmUnit))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            self.healthStore.execute(q)
        }
        if let avg { return avg }

        // Fallback: fetch samples and compute mean
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: hrType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            self.healthStore.execute(q)
        }
        guard !samples.isEmpty else {
            if let s = start, let e = end {
                return try await averageHR(in: DateInterval(start: s, end: e))
            }
            return nil
        }
        let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let values = samples.map { $0.quantity.doubleValue(for: bpmUnit) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func estimateMaxHR() -> Int {
        if let cached = cachedMaxHR { return cached }
        if let comps = try? healthStore.dateOfBirthComponents(),
           let year = comps.year {
            let age = max(0, Calendar.current.component(.year, from: Date()) - year)
            let est = max(120, min(210, 220 - age))
            cachedMaxHR = est
            return est
        }
        cachedMaxHR = 190
        return 190
    }

    // New: config-aware breakdown; default config is Apple-style
    func zoneBreakdown(for interval: DateInterval, maxHR: Int? = nil, config: HRZoneConfig = HRZoneConfig()) async throws -> ZoneBreakdown {
        let cfg = config.normalized()
        let key = intervalCacheKey(interval: interval, config: cfg)
        if let cached = await hrCache.get(key) { return cached }

        let samples = try await fetchHeartRateSamples(in: interval)
        guard !samples.isEmpty else {
            let empty = ZoneBreakdown()
            await hrCache.set(key, value: empty)
            return empty
        }

        let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let maxHRValue = Double(maxHR ?? estimateMaxHR())
        let restingHRValue = Double(await estimateRestingHR())

        var durations = Array(repeating: 0.0, count: 5)
        var total: TimeInterval = 0

        let clampedEnd = interval.end

        for i in 0..<samples.count {
            let s = samples[i]
            let nextStart = (i + 1 < samples.count) ? samples[i + 1].startDate : clampedEnd

            let segStart: Date = (i == 0) ? interval.start : max(s.startDate, interval.start)
            let segEnd: Date = min(nextStart, clampedEnd)
            let dt = segEnd.timeIntervalSince(segStart)
            guard dt > 0 else { continue }

            let bpm = s.quantity.doubleValue(for: bpmUnit)
            let idx = HRZones.index(for: bpm, maxHR: maxHRValue, restingHR: restingHRValue, config: cfg)
            durations[idx] += dt
            total += dt
        }

        let result = ZoneBreakdown(durations: durations, total: total)
        await hrCache.set(key, value: result)
        return result
    }

    // Back-compat: existing signature (uses default Apple-style config)
    func zoneBreakdown(for interval: DateInterval, maxHR: Int? = nil) async throws -> ZoneBreakdown {
        try await zoneBreakdown(for: interval, maxHR: maxHR, config: HRZoneConfig())
    }

    func zoneBreakdown(forRun start: Date, end: Date, config: HRZoneConfig = HRZoneConfig()) async throws -> ZoneBreakdown {
        let interval = DateInterval(start: start, end: end)
        return try await zoneBreakdown(for: interval, maxHR: nil, config: config)
    }

    private func intervalCacheKey(interval: DateInterval, config: HRZoneConfig) -> String {
        "\(interval.start.timeIntervalSince1970)|\(interval.end.timeIntervalSince1970)|\(config.z2)|\(config.z3)|\(config.z4)|\(config.z5)"
    }

    // MARK: - Workout route (GPS) APIs

    private func fetchWorkout(by uuid: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: uuid)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                  predicate: predicate,
                                  limit: 1,
                                  sortDescriptors: [sort]) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            self.healthStore.execute(q)
        }
        return workouts.first
    }

    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLLocation], Error>) in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locsOrNil, done, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let locs = locsOrNil {
                    collected.append(contentsOf: locs)
                }
                if done {
                    continuation.resume(returning: collected)
                }
            }
            self.healthStore.execute(query)
        }
    }

    // Returns the polyline as an array of coordinates (order preserved).
    func fetchRouteCoordinates(for workoutUUID: UUID) async throws -> [CLLocationCoordinate2D] {
        guard let workout = try await fetchWorkout(by: workoutUUID) else {
            return []
        }
        let routeType = HKSeriesType.workoutRoute()
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkoutRoute], Error>) in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let q = HKSampleQuery(sampleType: routeType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            self.healthStore.execute(q)
        }

        var coords: [CLLocationCoordinate2D] = []
        for route in routes {
            let locs = try await locations(for: route)
            coords.append(contentsOf: locs.map { $0.coordinate })
        }
        return coords
    }

    // MARK: - De-duplication helpers (RunSummary-based)

    private func deduplicateByOverlapLongestDuration(_ items: [RunSummary],
                                                     overlapThreshold: TimeInterval = 60) -> [RunSummary] {
        guard !items.isEmpty else { return [] }

        let sorted = items.sorted { $0.startDate < $1.startDate }
        var groups: [[RunSummary]] = []
        var current: [RunSummary] = []

        for s in sorted {
            if let last = current.last, overlaps(last, s, overlapThreshold: overlapThreshold) {
                current.append(s)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [s]
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map { chooseLongest(from: $0) }
    }

    private func overlaps(_ a: RunSummary, _ b: RunSummary, overlapThreshold: TimeInterval) -> Bool {
        let latestStart = max(a.startDate, b.startDate)
        let earliestEnd = min(a.endDate, b.endDate)
        let overlap = earliestEnd.timeIntervalSince(latestStart)
        return overlap >= overlapThreshold
    }

    private func chooseLongest(from group: [RunSummary]) -> RunSummary {
        return group.max { a, b in
            if a.duration != b.duration { return a.duration < b.duration }
            if a.distanceMiles != b.distanceMiles { return a.distanceMiles < b.distanceMiles }
            return a.startDate > b.startDate
        }!
    }

    // Map to friendly labels where possible
    private func sourceNameLabel(forAppName name: String, bundleID: String) -> String {
        let lowerName = name.lowercased()
        let lowerBundle = bundleID.lowercased()

        if lowerBundle.contains("com.strava") || lowerName.contains("strava") {
            return "Strava"
        }
        if lowerBundle.contains("com.apple.fitness") || lowerName == "fitness" || lowerName.contains("apple fitness") {
            return "Apple Fitness"
        }
        return name
    }
}

// Formatting helpers
extension TimeInterval {
    var asHMS: String {
        let totalSeconds = Int(self.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

extension Double {
    var asPaceMinPerMile: String {
        let totalSeconds = Int((self * 60.0).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d /mi", minutes, seconds)
    }
}
