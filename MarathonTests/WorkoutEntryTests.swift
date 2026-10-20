import XCTest
@testable import Marathon

final class WorkoutEntryTests: XCTestCase {
    @MainActor
    func testCodableRoundTripPreservesSharingFields() throws {
        let entry = WorkoutEntry(
            id: "run-1",
            userId: "runner-1",
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 1_600),
            distanceMeters: 1609.344,
            durationSec: 600,
            avgHR: 151,
            source: "apple",
            runType: .tempo,
            isManual: false,
            notes: "steady",
            healthKitUUID: UUID(uuidString: "8CFACB36-013A-45C1-95D6-FC0907D889F1"),
            isShared: true,
            teamId: "team-a",
            sharedRoutePoints: [40.0, -105.0, 40.001, -105.001]
        )

        let decoded = try JSONDecoder().decode(WorkoutEntry.self, from: JSONEncoder().encode(entry))

        var expected = entry
        expected.sharedRoutePoints = nil
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(decoded.sharedRoutePoints)
        let encoded = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sharedRoutePoints"))
        XCTAssertEqual(try XCTUnwrap(decoded.paceSecPerMile), 600, accuracy: 0.000_001)
    }

    @MainActor
    func testLegacyPayloadWithoutSharingFieldsFailsClosed() throws {
        let legacy = LegacyWorkoutEntry(
            id: "legacy-run",
            userId: "runner-1",
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 1_600),
            distanceMeters: 1609.344,
            durationSec: 600,
            avgHR: nil,
            source: "apple",
            runType: .recovery,
            isManual: false,
            notes: nil
        )

        let decoded = try JSONDecoder().decode(WorkoutEntry.self, from: JSONEncoder().encode(legacy))

        XCTAssertFalse(decoded.isShared)
        XCTAssertEqual(decoded.teamId, "default")
        XCTAssertNil(decoded.sharedRoutePoints)
    }

    private struct LegacyWorkoutEntry: Codable {
        var id: String
        var userId: String
        var start: Date
        var end: Date
        var distanceMeters: Double
        var durationSec: Double
        var avgHR: Double?
        var source: String
        var runType: RunType
        var isManual: Bool
        var notes: String?
    }
}
