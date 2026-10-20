import XCTest
@testable import Marathon

final class PlanEngineTests: XCTestCase {
    @MainActor
    func testOpeningWeekUsesConfiguredMileage() {
        var settings = PlanRuleSettings.defaultForAthens()
        settings.startDate = localDate(year: 2026, month: 3, day: 2)
        settings.initRecoveryMi = 4
        settings.initTempoMi = 5
        settings.initLongMi = 6

        let target = PlanEngine().weeklyTarget(for: settings.startDate, settings: settings)

        XCTAssertEqual(target.suggested.recovery, 4, accuracy: 0.000_001)
        XCTAssertEqual(target.suggested.tempo, 5, accuracy: 0.000_001)
        XCTAssertEqual(target.suggested.long, 6, accuracy: 0.000_001)
        XCTAssertEqual(target.requiredWeeklyMiles, 15, accuracy: 0.000_001)
    }

    @MainActor
    func testOpeningWeekAppliesOneMileFloor() {
        var settings = PlanRuleSettings.defaultForAthens()
        settings.startDate = localDate(year: 2026, month: 3, day: 2)
        settings.initRecoveryMi = 0
        settings.initTempoMi = -2
        settings.initLongMi = 0.5

        let target = PlanEngine().weeklyTarget(for: settings.startDate, settings: settings)

        XCTAssertEqual(target.suggested.recovery, 1, accuracy: 0.000_001)
        XCTAssertEqual(target.suggested.tempo, 1, accuracy: 0.000_001)
        XCTAssertEqual(target.suggested.long, 1, accuracy: 0.000_001)
    }

    @MainActor
    private func localDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return mondayOfWeek(for: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)
    }
}
