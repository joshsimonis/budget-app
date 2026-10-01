/// A public holiday.
public struct Holiday: Hashable, Codable, Sendable {
    public var date: LocalDate
    public var name: String

    public init(date: LocalDate, name: String) {
        self.date = date
        self.name = name
    }
}

/// Easter Sunday (anonymous Gregorian algorithm).
public enum Easter {
    public static func sunday(in year: Int) -> LocalDate {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return LocalDate(year, month, day)
    }
}

/// Victorian public holidays, worked out by rule.
public enum VicHolidays {
    public static func holidays(in year: Int) -> [Holiday] {
        var list: [Holiday] = []
        func add(_ date: LocalDate, _ name: String) { list.append(Holiday(date: date, name: name)) }

        let newYear = LocalDate(year, 1, 1)
        add(newYear, "New Year's Day")
        if newYear.weekday == .saturday { add(LocalDate(year, 1, 3), "New Year's Day (additional)") }
        if newYear.weekday == .sunday { add(LocalDate(year, 1, 2), "New Year's Day (additional)") }

        let australiaDay = LocalDate(year, 1, 26)
        add(australiaDay, "Australia Day")
        if australiaDay.weekday == .saturday { add(LocalDate(year, 1, 28), "Australia Day (additional)") }
        if australiaDay.weekday == .sunday { add(LocalDate(year, 1, 27), "Australia Day (additional)") }

        add(LocalDate.nthWeekday(2, .monday, year: year, month: 3), "Labour Day")

        let easter = Easter.sunday(in: year)
        add(easter.adding(days: -2), "Good Friday")
        add(easter.adding(days: -1), "Easter Saturday")
        add(easter, "Easter Sunday")
        add(easter.adding(days: 1), "Easter Monday")

        add(LocalDate(year, 4, 25), "ANZAC Day")
        add(LocalDate.nthWeekday(2, .monday, year: year, month: 6), "King's Birthday")

        // Set each year by the Victorian Government; usually the day before the last Saturday in September.
        add(LocalDate.lastWeekday(.saturday, year: year, month: 9).adding(days: -1), "Friday before the AFL Grand Final (estimated)")

        add(LocalDate.nthWeekday(1, .tuesday, year: year, month: 11), "Melbourne Cup")

        let christmas = LocalDate(year, 12, 25)
        add(christmas, "Christmas Day")
        add(LocalDate(year, 12, 26), "Boxing Day")
        switch christmas.weekday {
        case .friday:
            add(LocalDate(year, 12, 28), "Boxing Day (additional)")
        case .saturday:
            add(LocalDate(year, 12, 27), "Christmas Day (additional)")
            add(LocalDate(year, 12, 28), "Boxing Day (additional)")
        case .sunday:
            add(LocalDate(year, 12, 27), "Christmas Day (additional)")
        default:
            break
        }
        return list.sorted { $0.date < $1.date }
    }
}

/// Public holidays plus weekends, used for business-day adjustment and counting work days.
public struct HolidayCalendar: Sendable {
    public enum Region: String, Codable, Sendable, CaseIterable {
        case victoria = "VIC"
        case none = "NONE"
    }

    public let region: Region
    public let extraHolidays: [Holiday]
    public let removedDates: Set<LocalDate>
    private let years: ClosedRange<Int>
    private let holidaysByDay: [Int32: String]

    public init(
        region: Region = .victoria,
        years: ClosedRange<Int> = 2015...2045,
        extra: [Holiday] = [],
        removed: [LocalDate] = []
    ) {
        self.region = region
        self.extraHolidays = extra
        self.removedDates = Set(removed)
        self.years = years
        var map: [Int32: String] = [:]
        if region == .victoria {
            for year in years {
                for holiday in VicHolidays.holidays(in: year) where !removedDates.contains(holiday.date) {
                    map[holiday.date.dayNumber] = holiday.name
                }
            }
        }
        for holiday in extra where !removedDates.contains(holiday.date) {
            map[holiday.date.dayNumber] = holiday.name
        }
        holidaysByDay = map
    }

    /// No public holidays at all (weekends still aren't business days).
    public static let weekendsOnly = HolidayCalendar(region: .none)

    public func holidayName(_ date: LocalDate) -> String? {
        if years.contains(date.year) || region == .none {
            return holidaysByDay[date.dayNumber]
        }
        if removedDates.contains(date) { return nil }
        if let extra = extraHolidays.first(where: { $0.date == date }) { return extra.name }
        return VicHolidays.holidays(in: date.year).first { $0.date == date }?.name
    }

    public func isHoliday(_ date: LocalDate) -> Bool { holidayName(date) != nil }

    public func isBusinessDay(_ date: LocalDate) -> Bool {
        !date.weekday.isWeekend && !isHoliday(date)
    }

    public func holidays(in span: DateSpan) -> [Holiday] {
        span.dates.compactMap { date in holidayName(date).map { Holiday(date: date, name: $0) } }
    }

    public func adjust(_ date: LocalDate, _ adjustment: BusinessDayAdjustment) -> LocalDate {
        var result = date
        switch adjustment {
        case .none:
            break
        case .following:
            while !isBusinessDay(result) { result = result.adding(days: 1) }
        case .preceding:
            while !isBusinessDay(result) { result = result.adding(days: -1) }
        }
        return result
    }
}
