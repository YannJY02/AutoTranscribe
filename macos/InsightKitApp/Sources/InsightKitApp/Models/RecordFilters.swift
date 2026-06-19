import Foundation

enum RecordTimeFilter: String, CaseIterable, Identifiable {
    case thisWeek
    case thisMonth
    case older

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisWeek:
            return "本周"
        case .thisMonth:
            return "本月"
        case .older:
            return "更早"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .thisWeek:
            return "records_time_filter_week"
        case .thisMonth:
            return "records_time_filter_month"
        case .older:
            return "records_time_filter_older"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .thisWeek:
            let lhs = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            let rhs = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return lhs.yearForWeekOfYear == rhs.yearForWeekOfYear && lhs.weekOfYear == rhs.weekOfYear
        case .thisMonth:
            let lhs = calendar.dateComponents([.year, .month], from: date)
            let rhs = calendar.dateComponents([.year, .month], from: now)
            return lhs.year == rhs.year && lhs.month == rhs.month
        case .older:
            return !RecordTimeFilter.thisMonth.contains(date, now: now, calendar: calendar)
        }
    }
}

struct RecordFilterCriteria {
    var tags: Set<String> = []
    var type: MediaType?
    var timeFilter: RecordTimeFilter?
    var now: Date = Date()
    var calendar: Calendar = .current
}
