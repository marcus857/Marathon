import XCTest
@testable import Marathon

final class WeeklyReviewRequestBuilderTests: XCTestCase {
    @MainActor
    func testBuilderEncodesOnlyTheReviewAllowlist() throws {
        let timezone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let reviewedWeek = date("2026-10-05T06:00:00Z")
        let privateWorkoutID = "private-healthkit-activity-id"
        let privateUserID = "siwa-subject-must-not-leave-device"
        let privateNote = "Meet at my home address after the run"
        let selectedWorkout = WorkoutEntry(
            id: privateWorkoutID,
            userId: privateUserID,
            start: date("2026-10-07T15:00:00Z"),
            end: date("2026-10-07T15:40:00Z"),
            distanceMeters: milesToMeters(4.2),
            durationSec: 2_400,
            avgHR: 151,
            source: "Strava",
            runType: .tempo,
            isManual: false,
            notes: privateNote,
            healthKitUUID: UUID(),
            stravaActivityId: "private-strava-id",
            zones: ZoneBreakdown(durations: [100, 200, 300, 400, 500], total: 1_500),
            restingHR: 48,
            isShared: true,
            teamId: "private-team-id",
            sharedRoutePoints: [40.0, -105.0, 40.1, -105.1]
        )
        let teammateWorkout = WorkoutEntry(
            id: "teammate-private-id",
            userId: "teammate-subject",
            start: date("2026-10-08T15:00:00Z"),
            end: date("2026-10-08T15:30:00Z"),
            distanceMeters: milesToMeters(3),
            durationSec: 1_800,
            avgHR: nil,
            source: "apple",
            runType: .recovery,
            isManual: false
        )

        let request = try WeeklyReviewRequestBuilder.build(
            WeeklyReviewBuildInput(
                userID: privateUserID,
                reviewedWeek: reviewedWeek,
                workouts: [selectedWorkout, teammateWorkout],
                plan: PlanSplit(recovery: 3, tempo: 4, long: 8, note: "private plan note"),
                requiredRuns: 3,
                healthKitSyncState: .complete,
                lastSuccessfulImportAt: date("2026-10-12T10:00:00Z"),
                latestVO2Max: 46.5,
                latestVO2MaxObservedOn: date("2026-10-07T12:00:00Z"),
                breakReason: .travel,
                hasBreakNote: true,
                timezone: timezone,
                generatedAt: date("2026-10-12T12:00:00Z"),
                requestID: UUID(uuidString: "B051E609-1EE4-4FCB-84C4-6C44B1C1C2B2")!
            )
        )

        XCTAssertEqual(request.schemaVersion, "weekly-review-input/v1")
        XCTAssertEqual(request.reviewedWeekStart, "2026-10-05")
        XCTAssertEqual(request.weekState, .complete)
        XCTAssertEqual(request.workouts.count, 1)
        XCTAssertEqual(request.workouts.first?.source, .strava)
        XCTAssertEqual(request.workouts.first?.runType, .tempo)
        XCTAssertEqual(request.workouts.first?.zoneSeconds?.z5, 500)
        XCTAssertEqual(request.breakContext.reason, .travel)
        XCTAssertTrue(request.breakContext.hasNote)

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "schema_version", "request_id", "reviewed_week_start", "generated_at", "timezone",
                "week_state", "data_freshness", "plans", "workouts", "physiology", "break_context"
            ]
        )

        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in [
            privateWorkoutID, privateUserID, privateNote, "private-strava-id", "private-team-id",
            "healthKitUUID", "stravaActivityId", "sharedRoutePoints", "restingHR", "notes"
        ] {
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(forbidden), "Leaked: \(forbidden)")
        }
    }

    @MainActor
    func testBuilderPreservesIncompleteImportStateWithoutInventingFreshness() throws {
        let request = try WeeklyReviewRequestBuilder.build(
            WeeklyReviewBuildInput(
                userID: "runner-1",
                reviewedWeek: date("2026-10-05T06:00:00Z"),
                workouts: [],
                plan: PlanSplit(recovery: 2, tempo: 3, long: 5),
                requiredRuns: 3,
                healthKitSyncState: .failed,
                lastSuccessfulImportAt: nil,
                latestVO2Max: nil,
                latestVO2MaxObservedOn: nil,
                breakReason: .none,
                hasBreakNote: false,
                timezone: try XCTUnwrap(TimeZone(identifier: "America/Denver")),
                generatedAt: date("2026-10-12T12:00:00Z"),
                requestID: UUID(uuidString: "F6B52035-5510-4B7D-A2E5-7E1CCB458E8F")!
            )
        )

        XCTAssertEqual(request.dataFreshness.healthKitSyncState, .failed)
        XCTAssertNil(request.dataFreshness.lastSuccessfulImportAt)
        XCTAssertTrue(request.workouts.isEmpty)
    }

    @MainActor
    func testBuilderRejectsFutureWeekAndInvalidWorkout() throws {
        let timezone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let common = WeeklyReviewBuildInput(
            userID: "runner-1",
            reviewedWeek: date("2026-10-19T06:00:00Z"),
            workouts: [],
            plan: PlanSplit(recovery: 2, tempo: 3, long: 5),
            requiredRuns: 3,
            healthKitSyncState: .complete,
            lastSuccessfulImportAt: date("2026-10-12T11:00:00Z"),
            latestVO2Max: nil,
            latestVO2MaxObservedOn: nil,
            breakReason: .none,
            hasBreakNote: false,
            timezone: timezone,
            generatedAt: date("2026-10-12T12:00:00Z"),
            requestID: UUID()
        )
        XCTAssertThrowsError(try WeeklyReviewRequestBuilder.build(common)) { error in
            XCTAssertEqual(error as? WeeklyReviewRequestBuildError, .futureWeek)
        }

        let invalidWorkout = WorkoutEntry(
            id: "invalid-workout",
            userId: "runner-1",
            start: date("2026-10-07T15:00:00Z"),
            end: date("2026-10-07T15:30:00Z"),
            distanceMeters: .infinity,
            durationSec: 1_800,
            avgHR: nil,
            source: "apple",
            runType: .other,
            isManual: false
        )
        var invalidInput = common
        invalidInput.reviewedWeek = date("2026-10-05T06:00:00Z")
        invalidInput.workouts = [invalidWorkout]
        XCTAssertThrowsError(try WeeklyReviewRequestBuilder.build(invalidInput)) { error in
            XCTAssertEqual(error as? WeeklyReviewRequestBuildError, .invalidWorkout(id: "invalid-workout"))
        }
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }
}
