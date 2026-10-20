import XCTest
@testable import Marathon

final class HRZoneConfigTests: XCTestCase {
    @MainActor
    func testNormalizationClampsAndOrdersMalformedCutoffs() {
        let normalized = HRZoneConfig(z2: 1.2, z3: 0.1, z4: 0.1, z5: 0.1).normalized()

        XCTAssertGreaterThanOrEqual(normalized.z2, 0.5)
        XCTAssertLessThan(normalized.z2, normalized.z3)
        XCTAssertLessThan(normalized.z3, normalized.z4)
        XCTAssertLessThan(normalized.z4, normalized.z5)
        XCTAssertLessThanOrEqual(normalized.z5, 1.0)
    }

    @MainActor
    func testZoneIndexUsesUpperBoundCutoffs() {
        let config = HRZoneConfig.appleDefault

        XCTAssertEqual(config.zoneIndex(forHRR: 0.59), 0)
        XCTAssertEqual(config.zoneIndex(forHRR: 0.60), 1)
        XCTAssertEqual(config.zoneIndex(forHRR: 0.70), 2)
        XCTAssertEqual(config.zoneIndex(forHRR: 0.80), 3)
        XCTAssertEqual(config.zoneIndex(forHRR: 0.90), 4)
    }
}
