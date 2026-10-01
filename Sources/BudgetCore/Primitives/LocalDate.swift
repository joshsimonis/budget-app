/// A calendar date with no time or time zone, stored as days since 1970-01-01.
/// Using whole days avoids the classic "midnight in another time zone" bugs.
public struct LocalDate: Hashable, Comparable, Strideable, Sendable, Codable, CustomStringConvertible {
    public let dayNumber: Int32

    public init(dayNumber: Int32) {
        self.dayNumber = dayNumber
    }

    /// Creates a date; traps on an invalid date (use `init?(year:month:day:)` for user input).
    public init(_ year: Int, _ month: Int, _ day: Int) {
        guard let date = LocalDate(year: year, month: month, day: day) else {
            preconditionFailure("Invalid date \(year)-\(month)-\(day)")
        }
        self = date
    }

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= LocalDate.daysInMonth(year: year, month: month) else {
            return nil
        }
        dayNumber = Int32(LocalDate.daysFromCivil(year, month, day))
    }

    /// Parses "YYYY-MM-DD".
    public init?(iso text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        self.init(year: y, month: m, day: d)
    }

    // MARK: Components

    public var components: (year: Int, month: Int, day: Int) {
        LocalDate.civilFromDays(Int(dayNumber))
    }

    public var year: Int { components.year }
    public var month: Int { components.month }
    public var day: Int { components.day }

    /// 1970-01-01 was a Thursday.
    public var weekday: Weekday {
        Weekday(rawValue: IntMath.floorMod(Int(dayNumber) + 3, 7) + 1)!
    }

    // MARK: Arithmetic

    public func adding(days: Int) -> LocalDate {
        LocalDate(dayNumber: dayNumber + Int32(days))
    }

    /// Adds calendar months, clamping the day to the target month's length.
    public func adding(months: Int) -> LocalDate {
        let (y, m, d) = components
        let index = y * 12 + (m - 1) + months
        let newYear = IntMath.floorDiv(index, 12)
        let newMonth = IntMath.floorMod(index, 12) + 1
        let newDay = min(d, LocalDate.daysInMonth(year: newYear, month: newMonth))
        return LocalDate(newYear, newMonth, newDay)
    }

    public static func - (lhs: LocalDate, rhs: LocalDate) -> Int {
        Int(lhs.dayNumber) - Int(rhs.dayNumber)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool { lhs.dayNumber < rhs.dayNumber }

    public func distance(to other: LocalDate) -> Int { Int(other.dayNumber) - Int(dayNumber) }
    public func advanced(by n: Int) -> LocalDate { adding(days: n) }

    // MARK: Calendar helpers

    /// Monday on or before this date.
    public var startOfWeek: LocalDate { adding(days: -(weekday.rawValue - 1)) }
    public var endOfWeek: LocalDate { startOfWeek.adding(days: 6) }
    public var startOfMonth: LocalDate {
        let (y, m, _) = components
        return LocalDate(y, m, 1)
    }
    public var endOfMonth: LocalDate {
        let (y, m, _) = components
        return LocalDate(y, m, LocalDate.daysInMonth(year: y, month: m))
    }

    /// Month index (year × 12 + month − 1), handy for month arithmetic.
    public var monthIndex: Int {
        let (y, m, _) = components
        return y * 12 + (m - 1)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    /// The `n`th (1-based) given weekday in a month, e.g. 2nd Monday of March.
    public static func nthWeekday(_ n: Int, _ weekday: Weekday, year: Int, month: Int) -> LocalDate {
        let first = LocalDate(year, month, 1)
        let offset = IntMath.floorMod(weekday.rawValue - first.weekday.rawValue, 7)
        return first.adding(days: offset + (n - 1) * 7)
    }

    /// The last given weekday in a month.
    public static func lastWeekday(_ weekday: Weekday, year: Int, month: Int) -> LocalDate {
        let last = LocalDate(year, month, daysInMonth(year: year, month: month))
        let offset = IntMath.floorMod(last.weekday.rawValue - weekday.rawValue, 7)
        return last.adding(days: -offset)
    }

    // MARK: Formatting

    /// "2026-10-01"
    public var isoString: String {
        let (y, m, d) = components
        return "\(LocalDate.pad(y, 4))-\(LocalDate.pad(m, 2))-\(LocalDate.pad(d, 2))"
    }

    /// Australian short format "1/10/2026".
    public var shortString: String {
        let (y, m, d) = components
        return "\(d)/\(m)/\(y)"
    }

    /// "1 Oct" or "1 Oct 2026".
    public func dayMonth(includeYear: Bool = false) -> String {
        let (y, m, d) = components
        let text = "\(d) \(LocalDate.monthShortNames[m - 1])"
        return includeYear ? text + " \(y)" : text
    }

    public var description: String { isoString }

    public static let monthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                    "August", "September", "October", "November", "December"]

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    // MARK: Codable as "YYYY-MM-DD"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = LocalDate(iso: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }

    // MARK: Howard Hinnant's civil date algorithms

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
