//
//  ComplianceEngine.swift
//  Marathon
//

import Foundation

protocol ComplianceEngineProtocol {
    func summarize(weekStart: Date,
                   workouts: [WorkoutEntry],
                   requiredWeeklyMiles: Double,
                   latestVO2Max: Double?,
                   requiredRuns: Int) -> WeekSummary
}

struct ComplianceEngine: ComplianceEngineProtocol {
    func summarize(weekStart: Date,
                   workouts: [WorkoutEntry],
                   requiredWeeklyMiles: Double,
                   latestVO2Max: Double?,
                   requiredRuns: Int) -> WeekSummary {

        let start = mondayOfWeek(for: weekStart)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 24 * 60 * 60)

        let inWeek = workouts.filter { $0.start >= start && $0.start < end }
        let milesList = inWeek.map { metersToMiles($0.distanceMeters) }
        let runsCount = milesList.filter { $0 >= 1.0 }.count
        let sumMiles = milesList.reduce(0, +)

        let userId = inWeek.first?.userId ?? workouts.first?.userId ?? "unknown"
        let id = "\(userId)_\(isoDate(start))"
        let compliant = (runsCount >= requiredRuns) && (sumMiles >= requiredWeeklyMiles)

        return WeekSummary(id: id,
                           userId: userId,
                           weekStart: start,
                           requiredRuns: requiredRuns,
                           requiredWeeklyMiles: requiredWeeklyMiles,
                           actualRuns: runsCount,
                           actualMiles: sumMiles,
                           compliant: compliant,
                           latestVO2Max: latestVO2Max,
                           breakReason: .none,
                           breakNotes: nil)
    }

    private func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }
}
