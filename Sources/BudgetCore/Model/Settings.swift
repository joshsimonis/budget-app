import Foundation

public struct Settings: Hashable, Codable, Sendable {
    /// The time zone used for "today" and for dating bank transactions.
    public var timeZoneID: String
    public var holidayRegion: HolidayCalendar.Region
    /// Extra public holidays (e.g. the confirmed AFL Grand Final Friday).
    public var extraHolidays: [Holiday]
    /// Holidays from the built-in rules that you don't get.
    public var removedHolidays: [LocalDate]
    /// Days an overdue planned item stays "pending" before it's flagged as missed.
    public var graceDays: Int
    /// How far ahead to project.
    public var horizonMonths: Int
    /// How far back the grid starts.
    public var historyWeeks: Int
    /// Apply the $1,000 standard work-related deduction in year-end tax estimates.
    public var applyStandardDeduction: Bool
    /// Where pay days that land on a weekend or holiday move to.
    public var payDayAdjustment: BusinessDayAdjustment
    /// Running balances below this are highlighted.
    public var lowBalanceThreshold: Money?

    public init(
        timeZoneID: String = TimeZoneBridge.defaultIdentifier,
        holidayRegion: HolidayCalendar.Region = .victoria,
        extraHolidays: [Holiday] = [],
        removedHolidays: [LocalDate] = [],
        graceDays: Int = 4,
        horizonMonths: Int = 24,
        historyWeeks: Int = 8,
        applyStandardDeduction: Bool = true,
        payDayAdjustment: BusinessDayAdjustment = .preceding,
        lowBalanceThreshold: Money? = nil
    ) {
        self.timeZoneID = timeZoneID
        self.holidayRegion = holidayRegion
        self.extraHolidays = extraHolidays
        self.removedHolidays = removedHolidays
        self.graceDays = graceDays
        self.horizonMonths = horizonMonths
        self.historyWeeks = historyWeeks
        self.applyStandardDeduction = applyStandardDeduction
        self.payDayAdjustment = payDayAdjustment
        self.lowBalanceThreshold = lowBalanceThreshold
    }

    public func makeHolidayCalendar() -> HolidayCalendar {
        HolidayCalendar(region: holidayRegion, extra: extraHolidays, removed: removedHolidays)
    }

    public var timeZone: TimeZoneBridge { TimeZoneBridge(identifier: timeZoneID) }
}
