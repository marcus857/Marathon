//
//  WorkoutEntry.swift
//  Marathon
//

import Foundation

enum RunType: String, Codable, CaseIterable, Sendable {
    case recovery, tempo, long, other
}

struct WorkoutEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var userId: String
    var start: Date
    var end: Date
    var distanceMeters: Double
    var durationSec: Double
    var avgHR: Double?
    var source: String           // "apple" or "strava" or "manual"
    var runType: RunType
    var isManual: Bool
    var notes: String? = nil

    // Deep link identifiers (optional)
    var healthKitUUID: UUID? = nil
    var stravaActivityId: String? = nil

    // Optional embedded heart‑rate zone breakdown and resting HR used for classification
    var zones: ZoneBreakdown? = nil
    var restingHR: Int? = nil

    // Team feed sharing
    var isShared: Bool = false
    var teamId: String = "default"
    // Legacy route payload retained only so older local data can decode. New
    // imports and public CloudKit writes neither persist nor upload routes.
    var sharedRoutePoints: [Double]? = nil

    var miles: Double { distanceMeters / 1609.344 }
    var paceSecPerMile: Double? {
        Marathon.paceSecPerMile(distanceMeters: distanceMeters, durationSec: durationSec)
    }

    // Explicit memberwise initializer to match call sites (CloudKitManager.workout(from:) and others)
    nonisolated init(id: String,
         userId: String,
         start: Date,
         end: Date,
         distanceMeters: Double,
         durationSec: Double,
         avgHR: Double?,
         source: String,
         runType: RunType,
         isManual: Bool,
         notes: String? = nil,
         healthKitUUID: UUID? = nil,
         stravaActivityId: String? = nil,
         zones: ZoneBreakdown? = nil,
         restingHR: Int? = nil,
         isShared: Bool = false,
         teamId: String = "default",
         sharedRoutePoints: [Double]? = nil) {
        self.id = id
        self.userId = userId
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.durationSec = durationSec
        self.avgHR = avgHR
        self.source = source
        self.runType = runType
        self.isManual = isManual
        self.notes = notes
        self.healthKitUUID = healthKitUUID
        self.stravaActivityId = stravaActivityId
        self.zones = zones
        self.restingHR = restingHR
        self.isShared = isShared
        self.teamId = teamId
        self.sharedRoutePoints = sharedRoutePoints
    }

    // Backward-compatible decoding so older persisted/demo data (without these keys) still decodes.
    enum CodingKeys: String, CodingKey {
        case id, userId, start, end, distanceMeters, durationSec, avgHR, source, runType, isManual, notes
        case healthKitUUID, stravaActivityId, zones, restingHR
        case isShared, teamId, sharedRoutePoints
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        distanceMeters = try c.decode(Double.self, forKey: .distanceMeters)
        durationSec = try c.decode(Double.self, forKey: .durationSec)
        avgHR = try c.decodeIfPresent(Double.self, forKey: .avgHR)
        source = try c.decode(String.self, forKey: .source)
        runType = try c.decode(RunType.self, forKey: .runType)
        isManual = try c.decode(Bool.self, forKey: .isManual)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        healthKitUUID = try c.decodeIfPresent(UUID.self, forKey: .healthKitUUID)
        stravaActivityId = try c.decodeIfPresent(String.self, forKey: .stravaActivityId)
        zones = try c.decodeIfPresent(ZoneBreakdown.self, forKey: .zones)
        restingHR = try c.decodeIfPresent(Int.self, forKey: .restingHR)
        // Fail closed when a record does not carry an explicit sharing decision.
        isShared = try c.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId) ?? "default"
        // Deliberately discard legacy cached route payloads on read. Routes stay
        // in HealthKit and are no longer persisted or sent to CloudKit.
        sharedRoutePoints = nil
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(distanceMeters, forKey: .distanceMeters)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(avgHR, forKey: .avgHR)
        try c.encode(source, forKey: .source)
        try c.encode(runType, forKey: .runType)
        try c.encode(isManual, forKey: .isManual)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(healthKitUUID, forKey: .healthKitUUID)
        try c.encodeIfPresent(stravaActivityId, forKey: .stravaActivityId)
        try c.encodeIfPresent(zones, forKey: .zones)
        try c.encodeIfPresent(restingHR, forKey: .restingHR)
        try c.encode(isShared, forKey: .isShared)
        try c.encode(teamId, forKey: .teamId)
        // Do not encode legacy route coordinates into local caches or CloudKit
        // payloads. They remain solely in Apple Health.
    }
}
