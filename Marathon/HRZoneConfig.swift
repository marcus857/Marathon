// HRZoneConfig.swift

import Foundation

public struct HRZoneConfig: Codable, Hashable, Sendable {
    // HRR cutoffs for the upper bound of Z1..Z4 (Z5 is the remainder up to 100%).
    // Values are expressed as fractions of Heart Rate Reserve (0.0...1.0).
    // Typical Apple-style defaults: 0.60, 0.70, 0.80, 0.90
    public var z2: Double
    public var z3: Double
    public var z4: Double
    public var z5: Double

    nonisolated public init(z2: Double = 0.60, z3: Double = 0.70, z4: Double = 0.80, z5: Double = 0.90) {
        self.z2 = z2
        self.z3 = z3
        self.z4 = z4
        self.z5 = z5
    }

    // Apple default 5-zone HRR configuration
    nonisolated public static let appleDefault = HRZoneConfig()

    // Return a clamped, monotonically increasing variant (with small minimum gaps).
    nonisolated public func normalized() -> HRZoneConfig {
        let lo = 0.50
        let hi = 1.00
        let minGap = 0.005 // 0.5% minimal separation

        let a = max(lo, min(0.98, z2))
        let b = max(a + minGap, min(0.99, z3))
        let c = max(b + minGap, min(0.995, z4))
        var d = max(c + minGap, min(hi, z5))

        // Defensive: ensure z5 never exceeds 1.0
        if d > hi { d = hi }
        return HRZoneConfig(z2: a, z3: b, z4: c, z5: d)
    }

    // Convenience: ordered cutoffs [Z1<Z2<Z3<Z4<Z5]
    nonisolated public var cutoffs: [Double] {
        let n = normalized()
        return [n.z2, n.z3, n.z4, n.z5]
    }

    // Compute zone index (0...4) for a given HRR fraction (0...1).
    nonisolated public func zoneIndex(forHRR pct: Double) -> Int {
        let p = max(0.0, min(1.0, pct))
        let c = cutoffs
        if p < c[0] { return 0 }
        if p < c[1] { return 1 }
        if p < c[2] { return 2 }
        if p < c[3] { return 3 }
        return 4
    }

    // Convenience: closed ranges for each zone in HRR space (for visualizations)
    nonisolated public var bands: [ClosedRange<Double>] {
        let c = cutoffs
        return [
            0.50...c[0],
            c[0]...c[1],
            c[1]...c[2],
            c[2]...c[3],
            c[3]...1.00
        ]
    }
}
