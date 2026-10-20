import XCTest
@testable import Marathon

@MainActor
final class WeeklyReviewPreparationTests: XCTestCase {
    private let week = Date(timeIntervalSince1970: 1_791_763_200)
    private let now = Date(timeIntervalSince1970: 1_792_400_400)

    func testCompleteRequiresConfirmationAndRecentMatchingImport() {
        let record = WeeklyReviewImportRecord(userID: "runner", weekStart: week,
                                            completedAt: now.addingTimeInterval(-60), succeeded: true)
        XCTAssertEqual(record.syncState(userID: "runner", weekStart: week, userConfirmedData: true, now: now), .complete)
        XCTAssertEqual(record.syncState(userID: "runner", weekStart: week, userConfirmedData: false, now: now), .unknown)
        XCTAssertEqual(record.syncState(userID: "teammate", weekStart: week, userConfirmedData: true, now: now), .unknown)
        XCTAssertEqual(record.syncState(userID: "runner", weekStart: week.addingTimeInterval(604_800), userConfirmedData: true, now: now), .unknown)
    }

    func testStaleMissingAndFutureImportsAreNotComplete() {
        for completedAt in [now.addingTimeInterval(-901), now.addingTimeInterval(1), nil] as [Date?] {
            let record = WeeklyReviewImportRecord(userID: "runner", weekStart: week,
                                                completedAt: completedAt, succeeded: true)
            XCTAssertEqual(record.syncState(userID: "runner", weekStart: week, userConfirmedData: true, now: now), .unknown)
        }
    }

    func testFailedImportCannotBeOverriddenByConfirmation() {
        let record = WeeklyReviewImportRecord(userID: "runner", weekStart: week, completedAt: nil, succeeded: false)
        XCTAssertEqual(record.syncState(userID: "runner", weekStart: week, userConfirmedData: true, now: now), .failed)
    }

    func testStoreDefaultsToLimitedDataAndExcludesTeammates() throws {
        let store = WorkoutStore(startBackgroundSync: false)
        store.me.id = "review-test-runner"
        let selectedWeek = mondayOfWeek(for: Date().addingTimeInterval(-604_800))
        let start = selectedWeek.addingTimeInterval(3_600)
        store.workouts = [workout(user: store.me.id, start: start), workout(user: "teammate", start: start)]
        let request = try store.makeWeeklyReviewRequest(for: selectedWeek, userConfirmedData: true)
        XCTAssertEqual(request.workouts.count, 1)
        XCTAssertEqual(request.dataFreshness.healthKitSyncState, .unknown)
        XCTAssertNil(request.dataFreshness.lastSuccessfulImportAt)
        XCTAssertNil(request.physiology)
        store.weekBreaks[selectedWeek] = (.injury, "Another account's private note")
        let privateRequest = try store.makeWeeklyReviewRequest(for: selectedWeek, userConfirmedData: true)
        XCTAssertEqual(privateRequest.breakContext.reason, .none)
        XCTAssertFalse(privateRequest.breakContext.hasNote)
        XCTAssertEqual(privateRequest.dataFreshness.healthKitSyncState, .unknown)
    }

    func testTooManyWorkoutsAreRejectedNotTruncated() {
        let start = mondayOfWeek(for: now).addingTimeInterval(60)
        var input = buildInput(start: start)
        input.workouts = (0..<81).map { index in workout(user: "runner", start: start, id: "run-\(index)") }
        XCTAssertThrowsError(try WeeklyReviewRequestBuilder.build(input)) {
            XCTAssertEqual($0 as? WeeklyReviewRequestBuildError, .tooManyWorkouts)
        }
    }

    func testFutureWorkoutWithinCurrentWeekIsRejected() {
        var input = buildInput(start: mondayOfWeek(for: now))
        input.workouts = [workout(user: "runner", start: now.addingTimeInterval(60))]
        XCTAssertThrowsError(try WeeklyReviewRequestBuilder.build(input)) {
            XCTAssertEqual($0 as? WeeklyReviewRequestBuildError, .invalidWorkout(id: "run"))
        }
    }

    private func buildInput(start: Date) -> WeeklyReviewBuildInput {
        WeeklyReviewBuildInput(userID: "runner", reviewedWeek: start, workouts: [],
                              plan: PlanSplit(recovery: 2, tempo: 3, long: 5), requiredRuns: 3,
                              healthKitSyncState: .unknown, lastSuccessfulImportAt: nil,
                              latestVO2Max: nil, latestVO2MaxObservedOn: nil,
                              breakReason: .none, hasBreakNote: false, generatedAt: now)
    }

    private func workout(user: String, start: Date, id: String = "run") -> WorkoutEntry {
        WorkoutEntry(id: id, userId: user, start: start, end: start.addingTimeInterval(1_800),
                     distanceMeters: milesToMeters(3), durationSec: 1_800, avgHR: nil,
                     source: "apple", runType: .other, isManual: false)
    }
}
