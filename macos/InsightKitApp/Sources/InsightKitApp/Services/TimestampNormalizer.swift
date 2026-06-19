import Foundation

enum TimestampNormalizer {
    static func parse(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        return 0
    }

    static func normalize(_ value: String, duration: TimeInterval?) -> TimeInterval {
        let parsed = parse(value)
        guard let duration, duration > 0, parsed > duration + 1 else {
            return parsed
        }
        let secondsComponent = value.split(separator: ":").compactMap { Double($0) }.last ?? 0
        if duration < 60, secondsComponent <= duration + 1 {
            return secondsComponent
        }
        return duration
    }
}
