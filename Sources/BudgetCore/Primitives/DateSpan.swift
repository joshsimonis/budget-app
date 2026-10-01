/// An inclusive range of dates (start...end).
public struct DateSpan: Hashable, Sendable, Codable, CustomStringConvertible {
    public var start: LocalDate
    public var end: LocalDate

    public init(start: LocalDate, end: LocalDate) {
        precondition(start <= end, "DateSpan start \(start) is after end \(end)")
        self.start = start
        self.end = end
    }

    /// Returns nil when end < start.
    public static func make(_ start: LocalDate, _ end: LocalDate) -> DateSpan? {
        start <= end ? DateSpan(start: start, end: end) : nil
    }

    public init(_ start: LocalDate, _ end: LocalDate) {
        self.init(start: start, end: end)
    }

    public var dayCount: Int { end - start + 1 }

    public func contains(_ date: LocalDate) -> Bool { date >= start && date <= end }

    public func intersection(_ other: DateSpan) -> DateSpan? {
        DateSpan.make(max(start, other.start), min(end, other.end))
    }

    public func overlaps(_ other: DateSpan) -> Bool { intersection(other) != nil }

    /// Each date in the span, in order.
    public var dates: StrideThrough<LocalDate> { stride(from: start, through: end, by: 1) }

    public func expanded(by days: Int) -> DateSpan {
        DateSpan(start: start.adding(days: -days), end: end.adding(days: days))
    }

    public var description: String { "\(start)…\(end)" }
}
