//
//  PlanRuleSettings.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//


//
//  PlanRuleSettings.swift
//  Marathon
//

import Foundation

struct PlanRuleSettings: Codable {
    var startDate: Date
    var initRecoveryMi: Double
    var initTempoMi: Double
    var initLongMi: Double
    var maxWeeklyPctIncrease: Double    // default 0.10
    var consolidationEvery: Int         // default 4
    var consolidationDropPct: Double    // default 0.25
    var longRunBias: Double             // 0–1, default 0.8
    var targetPeakLongMi: Double
    var targetPeakWeeklyMi: Double

    static func defaultForAthens() -> PlanRuleSettings {
        var comps = DateComponents(); comps.year = 2025; comps.month = 11; comps.day = 1
        let start = Calendar.current.date(from: comps) ?? Date()
        return PlanRuleSettings(
            startDate: start,
            initRecoveryMi: 2.0,
            initTempoMi: 3.1,
            initLongMi: 3.1,
            maxWeeklyPctIncrease: 0.10,
            consolidationEvery: 4,
            consolidationDropPct: 0.25,
            longRunBias: 0.8,
            targetPeakLongMi: 20.0,
            targetPeakWeeklyMi: 45.0
        )
    }
}
