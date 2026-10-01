import Foundation
import Testing
@testable import BudgetCore

@Suite struct IntMathTests {
    @Test func floorDivisionHandlesNegatives() {
        #expect(IntMath.floorDiv(7, 7) == 1)
        #expect(IntMath.floorDiv(6, 7) == 0)
        #expect(IntMath.floorDiv(-1, 7) == -1)
        #expect(IntMath.floorDiv(-7, 7) == -1)
        #expect(IntMath.floorDiv(-8, 7) == -2)
        #expect(IntMath.ceilDiv(-8, 7) == -1)
        #expect(IntMath.ceilDiv(8, 7) == 2)
        #expect(IntMath.ceilDiv(7, 7) == 1)
        #expect(IntMath.floorMod(-1, 7) == 6)
    }

    @Test func roundedDivisionRoundsHalvesAwayFromZero() {
        #expect(IntMath.roundedDiv(5, 10) == 1)
        #expect(IntMath.roundedDiv(4, 10) == 0)
        #expect(IntMath.roundedDiv(-5, 10) == -1)
        #expect(IntMath.roundedDiv(-4, 10) == 0)
        #expect(IntMath.roundedDiv(2, 3) == 1)
        #expect(IntMath.roundedDiv(1, 3) == 0)
    }
}

@Suite struct MoneyTests {
    @Test func splitSpreadsRemainderToEarliestParts() {
        let parts = Money.dollars(300).split(7)
        #expect(parts.count == 7)
        #expect(parts.filter { $0.cents == 4286 }.count == 5)
        #expect(parts.filter { $0.cents == 4285 }.count == 2)
        #expect(parts.prefix(5).allSatisfy { $0.cents == 4286 })
        #expect(parts.reduce(Money.zero, +) == Money.dollars(300))
    }

    @Test func splitNegativeAmounts() {
        let parts = Money(cents: -10).split(3)
        #expect(parts.map(\.cents) == [-4, -3, -3])
    }

    @Test func scaledRoundsToNearestCent() {
        #expect(Money(cents: 100).scaled(1, 3).cents == 33)
        #expect(Money(cents: 200).scaled(1, 3).cents == 67)
        #expect(Money.dollars(112).scaled(100, 112) == Money.dollars(100))
        #expect(Money.dollars(1000).percent(basisPoints: 1200) == Money.dollars(120))
    }

    @Test(arguments: [
        ("1,234.56", 123_456),
        ("$12", 1200),
        ("-3.5", -350),
        ("(40.00)", -4000),
        ("12.345", 1235),
        ("0.994", 99),
        (".5", 50),
        ("+7", 700),
        ("-$2.10", -210),
    ] as [(String, Int64)])
    func parsing(text: String, cents: Int64) {
        #expect(Money(parsing: text)?.cents == cents)
    }

    @Test func parsingRejectsJunk() {
        #expect(Money(parsing: "") == nil)
        #expect(Money(parsing: "abc") == nil)
        #expect(Money(parsing: "1.2.3") == nil)
        #expect(Money(parsing: "$") == nil)
    }

    @Test func formatting() {
        #expect(MoneyFormat.string(Money(cents: 123_456)) == "$1,234.56")
        #expect(MoneyFormat.string(Money(cents: -5)) == "-$0.05")
        #expect(MoneyFormat.string(Money(cents: 100_000_000)) == "$1,000,000.00")
        #expect(MoneyFormat.string(Money(cents: 123_456), showCents: false) == "$1,235")
        #expect(MoneyFormat.string(Money(cents: 2000), showPlus: true) == "+$20.00")
        #expect(MoneyFormat.string(.zero) == "$0.00")
        #expect(MoneyFormat.plain(Money(cents: -123_405)) == "-1234.05")
    }

    @Test func codableAsCents() throws {
        let data = try JSONEncoder().encode([Money(cents: 1234)])
        #expect(String(decoding: data, as: UTF8.self) == "[1234]")
        #expect(try JSONDecoder().decode([Money].self, from: data) == [Money(cents: 1234)])
    }
}

@Suite struct LocalDateTests {
    @Test func roundTripsEveryDayFrom1900To2100() {
        var date = LocalDate(1900, 1, 1)
        let end = LocalDate(2100, 12, 31)
        var expected = (year: 1900, month: 1, day: 1)
        while date <= end {
            let c = date.components
            #expect(c.year == expected.year && c.month == expected.month && c.day == expected.day)
            if c != expected { return }
            #expect(LocalDate(c.year, c.month, c.day) == date)
            // advance expected manually
            if expected.day < LocalDate.daysInMonth(year: expected.year, month: expected.month) {
                expected.day += 1
            } else if expected.month < 12 {
                expected = (expected.year, expected.month + 1, 1)
            } else {
                expected = (expected.year + 1, 1, 1)
            }
            date = date.adding(days: 1)
        }
    }

    @Test func knownDates() {
        #expect(LocalDate(1970, 1, 1).dayNumber == 0)
        #expect(LocalDate(1970, 1, 1).weekday == .thursday)
        #expect(LocalDate(2026, 9, 21).weekday == .monday)
        #expect(LocalDate(2026, 10, 1).weekday == .thursday)
        #expect(LocalDate(2027, 2, 1).weekday == .monday)
        #expect(LocalDate(1969, 12, 31).dayNumber == -1)
        #expect(LocalDate(1969, 12, 31).weekday == .wednesday)
        #expect(LocalDate(2000, 2, 29).isoString == "2000-02-29")
        #expect(LocalDate(year: 2026, month: 2, day: 29) == nil)
        #expect(LocalDate(year: 2028, month: 2, day: 29) != nil)
        #expect(LocalDate(year: 1900, month: 2, day: 29) == nil)
    }

    @Test func weekAndMonthHelpers() {
        let d = LocalDate(2026, 10, 1)
        #expect(d.startOfWeek == LocalDate(2026, 9, 28))
        #expect(d.endOfWeek == LocalDate(2026, 10, 4))
        #expect(LocalDate(2026, 10, 4).startOfWeek == LocalDate(2026, 9, 28))
        #expect(LocalDate(2026, 10, 5).startOfWeek == LocalDate(2026, 10, 5))
        #expect(LocalDate(2027, 2, 14).endOfMonth == LocalDate(2027, 2, 28))
        #expect(LocalDate(2028, 2, 14).endOfMonth == LocalDate(2028, 2, 29))
        #expect(LocalDate(2027, 1, 31).adding(months: 1) == LocalDate(2027, 2, 28))
        #expect(LocalDate(2027, 1, 31).adding(months: -2) == LocalDate(2026, 11, 30))
        #expect(LocalDate.nthWeekday(2, .monday, year: 2026, month: 3) == LocalDate(2026, 3, 9))
        #expect(LocalDate.nthWeekday(1, .tuesday, year: 2026, month: 11) == LocalDate(2026, 11, 3))
        #expect(LocalDate.lastWeekday(.saturday, year: 2026, month: 9) == LocalDate(2026, 9, 26))
    }

    @Test func isoParsingAndCoding() throws {
        #expect(LocalDate(iso: "2026-10-01") == LocalDate(2026, 10, 1))
        #expect(LocalDate(iso: "2026-13-01") == nil)
        #expect(LocalDate(iso: "2026-1-01") == nil)
        let data = try JSONEncoder().encode([LocalDate(2026, 10, 1)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-10-01\"]")
        #expect(try JSONDecoder().decode([LocalDate].self, from: data) == [LocalDate(2026, 10, 1)])
    }

    @Test func formatting() {
        #expect(LocalDate(2026, 9, 21).shortString == "21/9/2026")
        #expect(LocalDate(2026, 9, 21).dayMonth() == "21 Sep")
        #expect(LocalDate(2026, 9, 21).dayMonth(includeYear: true) == "21 Sep 2026")
    }

    @Test func financialYear() {
        #expect(LocalDate(2026, 6, 30).financialYear == FinancialYear(startYear: 2025))
        #expect(LocalDate(2026, 7, 1).financialYear == FinancialYear(startYear: 2026))
        #expect(FinancialYear(startYear: 2026).label == "2026–27")
        #expect(FinancialYear(startYear: 2026).span.dayCount == 365)
        #expect(FinancialYear(startYear: 2027).span.dayCount == 366)
    }

    @Test func dateSpan() {
        let span = DateSpan(LocalDate(2026, 10, 1), LocalDate(2026, 10, 7))
        #expect(span.dayCount == 7)
        #expect(Array(span.dates).count == 7)
        #expect(span.contains(LocalDate(2026, 10, 7)))
        #expect(!span.contains(LocalDate(2026, 10, 8)))
        #expect(span.intersection(DateSpan(LocalDate(2026, 10, 7), LocalDate(2026, 10, 9))) == DateSpan(LocalDate(2026, 10, 7), LocalDate(2026, 10, 7)))
        #expect(span.intersection(DateSpan(LocalDate(2026, 10, 8), LocalDate(2026, 10, 9))) == nil)
    }
}

@Suite struct TimeZoneTests {
    let melbourne = TimeZoneBridge(identifier: "Australia/Melbourne")

    @Test func standardTimeOffsetIsPlusTen() throws {
        let instant = try #require(RFC3339.parse("2026-07-01T00:00:00+10:00"))
        #expect(melbourne.localDate(for: instant) == LocalDate(2026, 7, 1))
        #expect(melbourne.rfc3339StartOfDay(LocalDate(2026, 7, 1)) == "2026-07-01T00:00:00+10:00")
    }

    @Test func daylightSavingStartsFirstSundayOfOctober() throws {
        // 2026-10-04 02:00 AEST → 03:00 AEDT
        #expect(melbourne.rfc3339StartOfDay(LocalDate(2026, 10, 4)) == "2026-10-04T00:00:00+10:00")
        #expect(melbourne.rfc3339StartOfDay(LocalDate(2026, 10, 5)) == "2026-10-05T00:00:00+11:00")
        let late = try #require(RFC3339.parse("2026-10-04T23:59:00+11:00"))
        #expect(melbourne.localDate(for: late) == LocalDate(2026, 10, 4))
        let early = try #require(RFC3339.parse("2026-10-04T13:30:00Z")) // 00:30 on the 5th, AEDT
        #expect(melbourne.localDate(for: early) == LocalDate(2026, 10, 5))
    }

    @Test func daylightSavingEndsFirstSundayOfApril() throws {
        #expect(melbourne.rfc3339StartOfDay(LocalDate(2027, 4, 4)) == "2027-04-04T00:00:00+11:00")
        #expect(melbourne.rfc3339StartOfDay(LocalDate(2027, 4, 5)) == "2027-04-05T00:00:00+10:00")
        // A Sunday-night purchase stays in that week.
        let sundayNight = try #require(RFC3339.parse("2027-04-04T23:59:59+10:00"))
        #expect(melbourne.localDate(for: sundayNight) == LocalDate(2027, 4, 4))
        #expect(melbourne.localDate(for: sundayNight).startOfWeek == LocalDate(2027, 3, 29))
    }

    @Test func rfc3339Parsing() throws {
        let a = try #require(RFC3339.parse("2024-08-03T04:00:00+10:00"))
        let b = try #require(RFC3339.parse("2024-08-02T18:00:00Z"))
        #expect(a == b)
        let fractional = try #require(RFC3339.parse("2024-08-02T18:00:00.250Z"))
        #expect(abs(fractional.timeIntervalSince(b) - 0.25) < 0.0001)
        #expect(RFC3339.parse("2024-08-02T18:00:00") == nil)
        #expect(RFC3339.parse("2024-08-02") == nil)
        #expect(RFC3339.parse("2024-08-03T04:00:00+1000") == b)
        #expect(RFC3339.parse("2024-08-02T13:00:00-05:00") == b)
    }

    @Test func rfc3339Formatting() throws {
        let instant = try #require(RFC3339.parse("2026-10-01T09:05:07+10:00"))
        #expect(RFC3339.format(instant, offsetSeconds: 36_000) == "2026-10-01T09:05:07+10:00")
        #expect(RFC3339.format(instant, offsetSeconds: 0) == "2026-09-30T23:05:07+00:00")
        #expect(RFC3339.format(instant, offsetSeconds: -18_000) == "2026-09-30T18:05:07-05:00")
    }
}
