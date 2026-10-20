//
//  WeekSummary.swift
//  Marathon
//

import Foundation

enum BreakReason: String, Codable, CaseIterable {
    case none, illness, injury, travel, life, other
}

struct WeekSummary: Identifiable, Codable {
    var id: String                 // userId + ISO weekStart
    var userId: String
    var weekStart: Date            // Monday 00:00
    var requiredRuns: Int = 3
    var requiredWeeklyMiles: Double
    var actualRuns: Int
    var actualMiles: Double
    var compliant: Bool
    var latestVO2Max: Double?
    var breakReason: BreakReason
    var breakNotes: String?
}
