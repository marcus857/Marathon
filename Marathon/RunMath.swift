//
//  File.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//


//
//  RunMath.swift
//  Marathon
//

import Foundation

func metersToMiles(_ m: Double) -> Double { m / 1609.344 }
func milesToMeters(_ mi: Double) -> Double { mi * 1609.344 }

func paceSecPerMile(distanceMeters: Double, durationSec: Double) -> Double? {
    guard distanceMeters.isFinite,
          durationSec.isFinite,
          distanceMeters > 0,
          durationSec > 0 else { return nil }
    let miles = metersToMiles(distanceMeters)
    guard miles.isFinite, miles > 0 else { return nil }
    let pace = durationSec / miles
    return pace.isFinite && pace > 0 ? pace : nil
}

func secToHMS(_ s: Double) -> String {
    let total = Int(s.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let sec = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%d:%02d", m, sec)
}

// Monday 00:00 local time for the ISO week containing `date` (Monday→Sunday).
// Using ISO 8601 guarantees Sunday maps to the previous Monday.
func mondayOfWeek(for date: Date) -> Date {
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = Calendar.current.timeZone
    let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    let weekStart = cal.date(from: comps) ?? date
    return cal.startOfDay(for: weekStart)
}
