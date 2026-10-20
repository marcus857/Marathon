import XCTest
@testable import Marathon

final class RunMathTests: XCTestCase {
    @MainActor
    func testMileConversionAndPace() throws {
        XCTAssertEqual(metersToMiles(1609.344), 1, accuracy: 0.000_001)
        XCTAssertEqual(milesToMeters(1), 1609.344, accuracy: 0.000_001)
        let pace = try XCTUnwrap(paceSecPerMile(distanceMeters: 1609.344, durationSec: 600))
        XCTAssertEqual(pace, 600, accuracy: 0.000_001)
    }

    @MainActor
    func testPaceRejectsInvalidNumbers() {
        XCTAssertNil(paceSecPerMile(distanceMeters: 0, durationSec: 600))
        XCTAssertNil(paceSecPerMile(distanceMeters: 1609.344, durationSec: 0))
        XCTAssertNil(paceSecPerMile(distanceMeters: .infinity, durationSec: 600))
        XCTAssertNil(paceSecPerMile(distanceMeters: 1609.344, durationSec: .infinity))
        XCTAssertNil(paceSecPerMile(distanceMeters: .nan, durationSec: 600))
    }

    @MainActor
    func testSundayMapsToItsPriorMonday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let monday = mondayOfWeek(for: sunday)

        XCTAssertEqual(calendar.component(.weekday, from: monday), 2) // Monday
        XCTAssertLessThan(monday, sunday)
        XCTAssertEqual(calendar.dateComponents([.day], from: monday, to: sunday).day, 6)
    }
}
