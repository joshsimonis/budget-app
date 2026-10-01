/// How often something repeats. The phase comes from `Recurrence.anchor`.
public struct RecurrenceRule: Hashable, Codable, Sendable {
    public enum Unit: String, Codable, Sendable, CaseIterable {
        case once, day, week, month, year
    }

    public var unit: Unit
    /// Repeat every `interval` units (≥ 1). Ignored for `.once`.
    public var interval: Int
    /// For month/year rules: always use the last day of the month.
    public var monthEnd: Bool

    public init(unit: Unit, interval: Int = 1, monthEnd: Bool = false) {
        self.unit = unit
        self.interval = max(1, interval)
        self.monthEnd = monthEnd
    }

    public static let once = RecurrenceRule(unit: .once)
    public static let daily = RecurrenceRule(unit: .day)
    public static let weekly = RecurrenceRule(unit: .week)
    public static let fortnightly = RecurrenceRule(unit: .week, interval: 2)
    public static let fourWeekly = RecurrenceRule(unit: .week, interval: 4)
    public static let monthly = RecurrenceRule(unit: .month)
    public static let quarterly = RecurrenceRule(unit: .month, interval: 3)
    public static let yearly = RecurrenceRule(unit: .year)

    public var isRepeating: Bool { unit != .once }

    /// Average length of one period in days.
    public var approximateDays: Double {
        switch unit {
        case .once: 0
        case .day: Double(interval)
        case .week: Double(interval * 7)
        case .month: Double(interval) * 365.25 / 12
        case .year: Double(interval) * 365.25
        }
    }

    /// Occurrences per year, or nil for one-offs.
    public var periodsPerYear: Double? {
        unit == .once ? nil : 365.25 / approximateDays
    }

    /// "Weekly", "Fortnightly", "Every 3 weeks", "Monthly", "Quarterly", "Yearly"…
    public var frequencyLabel: String {
        switch (unit, interval) {
        case (.once, _): return "Once"
        case (.day, 1): return "Daily"
        case (.day, let n): return "Every \(n) days"
        case (.week, 1): return "Weekly"
        case (.week, 2): return "Fortnightly"
        case (.week, let n): return "Every \(n) weeks"
        case (.month, 1): return "Monthly"
        case (.month, 3): return "Quarterly"
        case (.month, 6): return "Every 6 months"
        case (.month, let n): return "Every \(n) months"
        case (.year, 1): return "Yearly"
        case (.year, let n): return "Every \(n) years"
        }
    }
}

/// What to do when an occurrence lands on a weekend or public holiday.
public enum BusinessDayAdjustment: String, Codable, Sendable, CaseIterable {
    case none, following, preceding
}

/// One generated occurrence: `original` is its identity, `date` is when it happens.
public struct Occurrence: Hashable, Sendable {
    public var original: LocalDate
    public var date: LocalDate

    public init(original: LocalDate, date: LocalDate) {
        self.original = original
        self.date = date
    }
}

/// A repeating schedule: a rule plus an anchor date that fixes its phase.
/// Dates are always computed from the anchor (31 Jan → 28 Feb → 31 Mar), never from
/// the previous clamped date, and work for indexes before the anchor too.
public struct Recurrence: Hashable, Codable, Sendable {
    public var rule: RecurrenceRule
    public var anchor: LocalDate
    public var adjustment: BusinessDayAdjustment

    public init(_ rule: RecurrenceRule, anchor: LocalDate, adjustment: BusinessDayAdjustment = .none) {
        self.rule = rule
        self.anchor = anchor
        self.adjustment = adjustment
    }

    public static func once(_ date: LocalDate) -> Recurrence {
        Recurrence(.once, anchor: date)
    }

    private var stepDays: Int {
        rule.unit == .week ? rule.interval * 7 : rule.interval
    }

    private var stepMonths: Int {
        rule.unit == .year ? rule.interval * 12 : rule.interval
    }

    /// The k-th occurrence (k may be negative). For one-offs every k gives the anchor.
    public func date(at k: Int) -> LocalDate {
        switch rule.unit {
        case .once:
            return anchor
        case .day, .week:
            return anchor.adding(days: k * stepDays)
        case .month, .year:
            let index = anchor.monthIndex + k * stepMonths
            let year = IntMath.floorDiv(index, 12)
            let month = IntMath.floorMod(index, 12) + 1
            let length = LocalDate.daysInMonth(year: year, month: month)
            let day = rule.monthEnd ? length : min(anchor.day, length)
            return LocalDate(year, month, day)
        }
    }

    /// Index of the last occurrence on or before `date`. For one-offs: 0 if the anchor
    /// is on or before `date`, otherwise nil.
    public func index(onOrBefore date: LocalDate) -> Int? {
        switch rule.unit {
        case .once:
            return anchor <= date ? 0 : nil
        case .day, .week:
            return IntMath.floorDiv(date - anchor, stepDays)
        case .month, .year:
            var k = IntMath.floorDiv(date.monthIndex - anchor.monthIndex, stepMonths)
            if self.date(at: k) > date { k -= 1 }
            return k
        }
    }

    /// Unadjusted occurrence dates within `span`, in order.
    public func originalDates(in span: DateSpan) -> [LocalDate] {
        if rule.unit == .once {
            return span.contains(anchor) ? [anchor] : []
        }
        guard let before = index(onOrBefore: span.start.adding(days: -1)) else { return [] }
        var result: [LocalDate] = []
        var k = before + 1
        while true {
            let d = date(at: k)
            if d > span.end { break }
            if d >= span.start { result.append(d) }
            k += 1
        }
        return result
    }

    /// Occurrences whose adjusted date falls inside `span`.
    public func occurrences(in span: DateSpan, calendar: HolidayCalendar) -> [Occurrence] {
        if adjustment == .none {
            return originalDates(in: span).map { Occurrence(original: $0, date: $0) }
        }
        return originalDates(in: span.expanded(by: 7)).compactMap { original in
            let actual = calendar.adjust(original, adjustment)
            return span.contains(actual) ? Occurrence(original: original, date: actual) : nil
        }
    }

    public func isOccurrence(_ date: LocalDate) -> Bool {
        guard let k = index(onOrBefore: date) else { return false }
        return self.date(at: k) == date
    }

    /// First unadjusted occurrence on or after `date`.
    public func next(onOrAfter date: LocalDate) -> LocalDate? {
        if rule.unit == .once { return anchor >= date ? anchor : nil }
        let k = (index(onOrBefore: date.adding(days: -1)) ?? -1) + 1
        return self.date(at: k)
    }

    /// Last unadjusted occurrence strictly before `date`.
    public func previous(before date: LocalDate) -> LocalDate? {
        if rule.unit == .once { return anchor < date ? anchor : nil }
        guard let k = index(onOrBefore: date.adding(days: -1)) else { return nil }
        return self.date(at: k)
    }

    /// "Weekly on Monday", "Monthly on the 15th", "Once on 13 Mar 2027"…
    public var label: String {
        switch rule.unit {
        case .once:
            return "Once on \(anchor.dayMonth(includeYear: true))"
        case .day:
            return rule.frequencyLabel
        case .week:
            return "\(rule.frequencyLabel) on \(anchor.weekday.name)"
        case .month:
            let day = rule.monthEnd ? "the last day" : "the \(Recurrence.ordinal(anchor.day))"
            return "\(rule.frequencyLabel) on \(day)"
        case .year:
            let day = rule.monthEnd ? "last day of \(LocalDate.monthShortNames[anchor.month - 1])" : anchor.dayMonth()
            return "\(rule.frequencyLabel) on \(day)"
        }
    }

    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        let suffix: String
        if (11...13).contains(tens) {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}
