/// How the grid groups days into columns.
public enum Granularity: String, Codable, Sendable, CaseIterable {
    case day, week, month

    public var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// One column of the grid.
public struct Bucket: Hashable, Sendable, Identifiable {
    public var index: Int
    public var span: DateSpan
    /// e.g. "21/9/2026" (week), "1/10" (day), "Oct 2026" (month).
    public var title: String
    /// e.g. "Thu" for a day.
    public var subtitle: String
    public var containsToday: Bool
    public var isPast: Bool

    public var id: Int { index }
}

public enum Bucketing {
    /// Columns covering the horizon. Weeks start on Monday; the first and last columns are
    /// clipped to the horizon.
    public static func buckets(for horizon: DateSpan, granularity: Granularity, today: LocalDate) -> [Bucket] {
        var result: [Bucket] = []
        var start = horizon.start
        while start <= horizon.end {
            let naturalEnd: LocalDate
            switch granularity {
            case .day: naturalEnd = start
            case .week: naturalEnd = start.endOfWeek
            case .month: naturalEnd = start.endOfMonth
            }
            let span = DateSpan(start: start, end: min(naturalEnd, horizon.end))
            let labelDate: LocalDate
            switch granularity {
            case .day: labelDate = start
            case .week: labelDate = start.startOfWeek
            case .month: labelDate = start.startOfMonth
            }
            let title: String
            let subtitle: String
            switch granularity {
            case .day:
                title = "\(labelDate.day)/\(labelDate.month)"
                subtitle = labelDate.weekday.shortName
            case .week:
                title = labelDate.shortString
                subtitle = "Week"
            case .month:
                title = "\(LocalDate.monthShortNames[labelDate.month - 1]) \(labelDate.year)"
                subtitle = ""
            }
            result.append(Bucket(
                index: result.count,
                span: span,
                title: title,
                subtitle: subtitle,
                containsToday: span.contains(today),
                isPast: span.end < today
            ))
            start = span.end.adding(days: 1)
        }
        return result
    }
}
