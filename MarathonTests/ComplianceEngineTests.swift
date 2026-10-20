import XCTest
@testable import Marathon

final class ComplianceEngineTests: XCTestCase {
    @MainActor
    func testWeekWindowIncludesMondayAndExcludesNextMonday() {
        let weekStart = mondayOfWeek(for: Date())
        let qualifying = workout(id: "included", start: weekStart, miles: 3)
        let nextWeek = workout(id: "excluded", start: weekStart.addingTimeInterval(7 * 24 * 60 * 60), miles: 10)

        let summary = ComplianceEngine().summarize(
            weekStart: weekStart,
            workouts: [qualifying, nextWeek],
            requiredWeeklyMiles: 3,
            latestVO2Max: nil,
            requiredRuns: 1
        )

        XCTAssertEqual(summary.userId, "runner-1")
        XCTAssertEqual(summary.actualRuns, 1)
        XCTAssertEqual(summary.actualMiles, 3, accuracy: 0.000_001)
        XCTAssertTrue(summary.compliant)
    }

    @MainActor
    func testSubMileWorkoutAddsMileageButNotRunCount() {
        let weekStart = mondayOfWeek(for: Date())
        let shortRun = workout(id: "short", start: weekStart.addingTimeInterval(60 * 60), miles: 0.75)

        let summary = ComplianceEngine().summarize(
            weekStart: weekStart,
            workouts: [shortRun],
            requiredWeeklyMiles: 0.75,
            latestVO2Max: nil,
            requiredRuns: 1
        )

        XCTAssertEqual(summary.actualRuns, 0)
        XCTAssertEqual(summary.actualMiles, 0.75, accuracy: 0.000_001)
        XCTAssertFalse(summary.compliant)
    }

    @MainActor
    private func workout(id: String, start: Date, miles: Double) -> WorkoutEntry {
        WorkoutEntry(
            id: id,
            userId: "runner-1",
            start: start,
            end: start.addingTimeInterval(600),
            distanceMeters: milesToMeters(miles),
            durationSec: 600,
            avgHR: nil,
            source: "manual",
            runType: .other,
            isManual: true
        )
    }
}
