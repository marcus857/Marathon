//
//  FunFactStore.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import Foundation

struct DatedFunFact: Identifiable, Hashable {
    let date: Date
    let fact: FunFact
    var id: Date { date }
}

final class FunFactStore {
    var facts: [FunFact] = FunFact.seeded

    func dailyFact(date: Date = Date()) -> FunFact {
        FunFact.daily(for: date, from: facts)
    }

    // History from a given start to end date (inclusive), one fact per calendar day.
    func history(from startDate: Date, to endDate: Date = Date()) -> [DatedFunFact] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let end = cal.startOfDay(for: endDate)
        guard start <= end else { return [] }

        var cursor = start
        var results: [DatedFunFact] = []

        while cursor <= end {
            let fact = dailyFact(date: cursor)
            results.append(DatedFunFact(date: cursor, fact: fact))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(24*3600)
        }
        return results
    }

    // History from Nov 1 (current season) to today (inclusive).
    // If today is before Nov 1 of this year, we use Nov 1 of the previous year.
    func historySinceNov1(to endDate: Date = Date()) -> [DatedFunFact] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: endDate)

        var comps = cal.dateComponents([.year], from: end)
        comps.month = 11; comps.day = 1
        let nov1ThisYear = cal.date(from: comps) ?? end

        let seasonStart: Date
        if end >= nov1ThisYear {
            seasonStart = nov1ThisYear
        } else {
            // Use Nov 1 of previous year
            var prev = DateComponents()
            prev.year = -1
            let lastYear = cal.date(byAdding: prev, to: nov1ThisYear) ?? nov1ThisYear
            seasonStart = lastYear
        }
        return history(from: seasonStart, to: end)
    }
}
