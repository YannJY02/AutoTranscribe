import Foundation

enum AudioSampleLimiter {
    static func limit(_ sample: Float, ceiling: Float = 0.98) -> Float {
        guard sample.isFinite else { return 0 }
        let safeCeiling = min(max(ceiling, 0.1), 0.999)
        return min(max(sample, -safeCeiling), safeCeiling)
    }

    static func mixedGain(micWeight: Float, systemWeight: Float, headroom: Float) -> Float {
        let total = abs(micWeight) + abs(systemWeight)
        guard total > 0 else { return 1 }
        let safeHeadroom = min(max(headroom, 0.1), 0.999)
        return min(1, safeHeadroom / total)
    }
}
