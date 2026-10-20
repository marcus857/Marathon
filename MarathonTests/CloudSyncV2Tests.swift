import XCTest
@testable import Marathon

final class CloudSyncV2Tests: XCTestCase {
    @MainActor
    func testTeamProjectionIsAnAllowlistNotAWorkoutEncoding() throws {
        let privateID = "private-healthkit-uuid-123"
        let privateUserID = "siwa-subject-should-not-leave-device"
        let privateNote = "Home address and recovery note"
        let workout = WorkoutEntry(
            id: privateID,
            userId: privateUserID,
            start: Date(timeIntervalSinceReferenceDate: 1_000_000),
            end: Date(timeIntervalSinceReferenceDate: 1_002_020),
            distanceMeters: milesToMeters(4.24),
            durationSec: 1_221,
            avgHR: 163,
            source: "strava",
            runType: .tempo,
            isManual: false,
            notes: privateNote,
            healthKitUUID: UUID(),
            stravaActivityId: "strava-private-id",
            zones: ZoneBreakdown(durations: [1, 2, 3, 4, 5], total: 15),
            restingHR: 51,
            isShared: true,
            teamId: "legacy-team",
            sharedRoutePoints: [40.0, -105.0, 40.1, -105.1]
        )

        let projection = try XCTUnwrap(
            TeamProjectionMapper.workout(
                from: workout,
                teamID: "team-public",
                memberID: "member-public",
                projectionID: "projection-public"
            )
        )

        XCTAssertEqual(projection.distanceMiles, 4.2, accuracy: 0.000_001)
        XCTAssertEqual(projection.durationMinutes, 20)
        XCTAssertEqual(projection.runType, .tempo)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "projection_id", "team_id", "member_id", "activity_day",
                "distance_miles", "duration_minutes", "run_type", "schema_version"
            ]
        )

        let encoded = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        for forbidden in [privateID, privateUserID, privateNote, "strava", "avgHR", "zone", "route"] {
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(forbidden), "Leaked: \(forbidden)")
        }
    }

    @MainActor
    func testProjectionRejectsInvalidDistances() {
        let invalid = WorkoutEntry(
            id: "private-id",
            userId: "private-user",
            start: Date(),
            end: Date().addingTimeInterval(60),
            distanceMeters: .infinity,
            durationSec: 60,
            avgHR: nil,
            source: "apple",
            runType: .other,
            isManual: false
        )

        XCTAssertNil(
            TeamProjectionMapper.workout(
                from: invalid,
                teamID: "team-public",
                memberID: "member-public",
                projectionID: "projection-public"
            )
        )
    }

    @MainActor
    func testV2StaysDisabledUntilSchemaAndDeviceValidationExist() {
        XCTAssertFalse(CloudSyncV2.isEnabled)
        XCTAssertEqual(CloudSyncV2.schemaVersion, 2)
    }
}
