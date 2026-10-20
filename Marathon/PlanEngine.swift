//
//  PlanEngine.swift
//  Marathon
//

import Foundation

protocol PlanEngineProtocol {
    func weeklyTarget(for weekStart: Date,
                      settings: PlanRuleSettings)
    -> (requiredWeeklyMiles: Double, suggested: (recovery: Double, tempo: Double, long: Double))

    // Expose whether a given week is a consolidation week using the anchored cadence
    func isConsolidationWeek(for weekStart: Date, settings: PlanRuleSettings) -> Bool
}

struct PlanEngine: PlanEngineProtocol {
    func weeklyTarget(for weekStart: Date,
                      settings: PlanRuleSettings)
    -> (requiredWeeklyMiles: Double, suggested: (recovery: Double, tempo: Double, long: Double)) {

        let cal = Calendar.current
        let startW = mondayOfWeek(for: settings.startDate)
        let targetW = mondayOfWeek(for: weekStart)
        let idx = weekIndex(startDate: startW, weekStart: targetW)

        // The opening week is part of the user-configurable plan, not a hidden
        // Athens-only constant. Clamp malformed saved settings to the same
        // one-mile floor used throughout the progression.
        var rec = max(settings.initRecoveryMi, 1.0)
        var tempo = max(settings.initTempoMi, 1.0)
        var long = max(settings.initLongMi, 1.0)
        var prevTotal = rec + tempo + long

        guard idx > 0 else {
            return (requiredWeeklyMiles: prevTotal,
                    suggested: (recovery: max(rec, 1), tempo: max(tempo, 1), long: max(long, 1)))
        }

        // Jan 1 of the year after the plan start (kept as‑is)
        let year = cal.component(.year, from: settings.startDate) + 1
        let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1))!

        // Anchor consolidation cadence at Dec 1 of the plan start year (Monday-normalized).
        let dec1Anchor = anchoredDec1(for: settings)

        for w in 1...idx {
            let weekDate = cal.date(byAdding: .day, value: 7 * w, to: startW) ?? targetW

            // Consolidation rule:
            // - Before Dec 1: use the legacy "every Nth week from start" rule.
            // - On/after Dec 1: use a cadence anchored to Dec 1 (e.g., Dec 1, Dec 29, Jan 26, ...).
            let isConsolidation: Bool = {
                if weekDate >= dec1Anchor {
                    let k = weekIndex(startDate: dec1Anchor, weekStart: weekDate) // weeks since Dec 1
                    guard settings.consolidationEvery > 0 else { return false }
                    return (k % settings.consolidationEvery) == 0
                } else {
                    return isConsolidationWeek(w, every: settings.consolidationEvery)
                }
            }()

            if isConsolidation {
                let f = max(0.0, 1.0 - settings.consolidationDropPct)
                rec = max(1.0, rec * f)
                tempo = max(1.0, tempo * f)
                long = max(1.0, long * f)
            } else {
                let beforeNY = weekDate < jan1
                var incRec = beforeNY ? 0.1 : 0.2
                var incTempo = beforeNY ? 0.2 : 0.2
                var incLong = beforeNY ? 1.0 : max(0.5, 1.0 * settings.longRunBias)

                let candTotal = (rec + incRec) + (tempo + incTempo) + (long + incLong)
                let maxTotal = prevTotal * (1.0 + settings.maxWeeklyPctIncrease)
                let incSum = incRec + incTempo + incLong
                if candTotal > maxTotal, incSum > 0 {
                    let scale = max(0, (maxTotal - prevTotal) / incSum)
                    incRec *= scale; incTempo *= scale; incLong *= scale
                }

                rec = max(1.0, rec + incRec)
                tempo = max(1.0, tempo + incTempo)
                long = max(1.0, long + incLong)
            }
            prevTotal = rec + tempo + long
        }

        let total = rec + tempo + long
        return (requiredWeeklyMiles: total,
                suggested: (recovery: rec, tempo: tempo, long: long))
    }

    // Tell callers if a specific week is consolidation using the anchored cadence.
    func isConsolidationWeek(for weekStart: Date, settings: PlanRuleSettings) -> Bool {
        let targetW = mondayOfWeek(for: weekStart)
        let startW = mondayOfWeek(for: settings.startDate)
        let dec1 = anchoredDec1(for: settings)

        guard settings.consolidationEvery > 0 else { return false }

        if targetW >= dec1 {
            let k = weekIndex(startDate: dec1, weekStart: targetW)
            return (k % settings.consolidationEvery) == 0
        } else {
            let idxFromStart = weekIndex(startDate: startW, weekStart: targetW)
            return ((idxFromStart + 1) % settings.consolidationEvery) == 0
        }
    }

    // Helpers
    func weekIndex(startDate: Date, weekStart: Date) -> Int {
        let cal = Calendar.current
        let a = mondayOfWeek(for: startDate)
        let b = mondayOfWeek(for: weekStart)
        let days = cal.dateComponents([.day], from: a, to: b).day ?? 0
        return max(0, days / 7)
    }

    func isConsolidationWeek(_ index: Int, every: Int) -> Bool {
        guard every > 0 else { return false }
        return (index + 1) % every == 0
    }

    // Dec 1 of the plan start year, normalized to Monday.
    private func anchoredDec1(for settings: PlanRuleSettings) -> Date {
        let cal = Calendar.current
        let y = cal.component(.year, from: settings.startDate)
        let d = cal.date(from: DateComponents(year: y, month: 12, day: 1)) ?? settings.startDate
        return mondayOfWeek(for: d)
    }
}
