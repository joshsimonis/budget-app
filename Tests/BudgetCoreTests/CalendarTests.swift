import Testing
@testable import BudgetCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }

@Suite struct RecurrenceTests {
    @Test func monthlyOnThe31stClampsFromTheAnchor() {
        let r = Recurrence(.monthly, anchor: d(2027, 1, 31))
        let dates = r.originalDates(in: DateSpan(d(2027, 1, 1), d(2027, 12, 31)))
        #expect(dates == [
            d(2027, 1, 31), d(2027, 2, 28), d(2027, 3, 31), d(2027, 4, 30), d(2027, 5, 31), d(2027, 6, 30),
            d(2027, 7, 31), d(2027, 8, 31), d(2027, 9, 30), d(2027, 10, 31), d(2027, 11, 30), d(2027, 12, 31),
        ])
    }

    @Test func lastDayOfMonthRule() {
        let r = Recurrence(RecurrenceRule(unit: .month, monthEnd: true), anchor: d(2027, 4, 30))
        #expect(r.originalDates(in: DateSpan(d(2028, 1, 1), d(2028, 3, 31))) == [d(2028, 1, 31), d(2028, 2, 29), d(2028, 3, 31)])
    }

    @Test func yearlyOn29FebruaryUses28thInOtherYears() {
        let r = Recurrence(.yearly, anchor: d(2028, 2, 29))
        #expect(r.originalDates(in: DateSpan(d(2027, 1, 1), d(2032, 12, 31))) ==
                [d(2027, 2, 28), d(2028, 2, 29), d(2029, 2, 28), d(2030, 2, 28), d(2031, 2, 28), d(2032, 2, 29)])
    }

    @Test func fortnightlyWorksBeforeTheAnchor() {
        let r = Recurrence(.fortnightly, anchor: d(2027, 2, 4))
        #expect(r.originalDates(in: DateSpan(d(2027, 1, 1), d(2027, 2, 28))) == [d(2027, 1, 7), d(2027, 1, 21), d(2027, 2, 4), d(2027, 2, 18)])
        #expect(r.index(onOrBefore: d(2027, 2, 3)) == -1)
        #expect(r.index(onOrBefore: d(2027, 2, 4)) == 0)
        #expect(r.date(at: -2) == d(2027, 1, 7))
        #expect(r.isOccurrence(d(2027, 1, 21)))
        #expect(!r.isOccurrence(d(2027, 1, 28)))
        #expect(r.next(onOrAfter: d(2027, 2, 5)) == d(2027, 2, 18))
        #expect(r.previous(before: d(2027, 2, 18)) == d(2027, 2, 4))
    }

    @Test func monthlyIndexAroundShortMonths() {
        let r = Recurrence(.monthly, anchor: d(2027, 1, 31))
        #expect(r.index(onOrBefore: d(2027, 2, 27)) == 0)
        #expect(r.index(onOrBefore: d(2027, 2, 28)) == 1)
        #expect(r.index(onOrBefore: d(2026, 12, 30)) == -2) // 31 Dec is after the 30th, so 30 Nov
        #expect(r.index(onOrBefore: d(2026, 12, 31)) == -1)
        #expect(r.next(onOrAfter: d(2027, 3, 1)) == d(2027, 3, 31))
    }

    @Test func everyThreeMonthsAndEveryTenDays() {
        let quarterly = Recurrence(.quarterly, anchor: d(2026, 8, 15))
        #expect(quarterly.originalDates(in: DateSpan(d(2026, 1, 1), d(2027, 6, 30))) ==
                [d(2026, 2, 15), d(2026, 5, 15), d(2026, 8, 15), d(2026, 11, 15), d(2027, 2, 15), d(2027, 5, 15)])
        let tenDays = Recurrence(RecurrenceRule(unit: .day, interval: 10), anchor: d(2026, 10, 1))
        #expect(tenDays.originalDates(in: DateSpan(d(2026, 9, 15), d(2026, 10, 25))) == [d(2026, 9, 21), d(2026, 10, 1), d(2026, 10, 11), d(2026, 10, 21)])
    }

    @Test func onceOnlyInsideSpan() {
        let r = Recurrence.once(d(2027, 3, 13))
        #expect(r.originalDates(in: DateSpan(d(2027, 3, 1), d(2027, 3, 31))) == [d(2027, 3, 13)])
        #expect(r.originalDates(in: DateSpan(d(2027, 4, 1), d(2027, 4, 30))).isEmpty)
        #expect(r.index(onOrBefore: d(2027, 3, 12)) == nil)
        #expect(r.isOccurrence(d(2027, 3, 13)))
    }

    @Test func businessDayAdjustmentKeepsOriginalIdentity() {
        let vic = HolidayCalendar()
        // Monthly on the 26th; 26 Dec 2026 is Boxing Day (Sat) and 28 Dec the additional holiday.
        let r = Recurrence(.monthly, anchor: d(2026, 10, 26), adjustment: .following)
        let occ = r.occurrences(in: DateSpan(d(2026, 12, 1), d(2027, 1, 31)), calendar: vic)
        #expect(occ == [
            Occurrence(original: d(2026, 12, 26), date: d(2026, 12, 29)),
            Occurrence(original: d(2027, 1, 26), date: d(2027, 1, 27)), // Australia Day (Tue)
        ])
        let preceding = Recurrence(.monthly, anchor: d(2026, 10, 26), adjustment: .preceding)
        #expect(preceding.occurrences(in: DateSpan(d(2026, 12, 1), d(2026, 12, 31)), calendar: vic) ==
                [Occurrence(original: d(2026, 12, 26), date: d(2026, 12, 24))])
    }

    @Test func adjustmentCanPullOccurrencesAcrossTheSpanEdge() {
        let vic = HolidayCalendar()
        // Saturday 3 Apr 2027 → Monday 5 Apr... (Easter Monday is 29 Mar 2027, so 5 Apr is a business day)
        let r = Recurrence(.monthly, anchor: d(2027, 1, 3), adjustment: .following)
        let april = r.occurrences(in: DateSpan(d(2027, 4, 4), d(2027, 4, 30)), calendar: vic)
        #expect(april == [Occurrence(original: d(2027, 4, 3), date: d(2027, 4, 5))])
    }

    @Test func labels() {
        #expect(Recurrence(.weekly, anchor: d(2026, 9, 21)).label == "Weekly on Monday")
        #expect(Recurrence(.fortnightly, anchor: d(2026, 10, 1)).label == "Fortnightly on Thursday")
        #expect(Recurrence(.monthly, anchor: d(2026, 10, 1)).label == "Monthly on the 1st")
        #expect(Recurrence(.monthly, anchor: d(2026, 10, 22)).label == "Monthly on the 22nd")
        #expect(Recurrence(.monthly, anchor: d(2026, 10, 13)).label == "Monthly on the 13th")
        #expect(Recurrence(RecurrenceRule(unit: .month, monthEnd: true), anchor: d(2026, 10, 31)).label == "Monthly on the last day")
        #expect(Recurrence(.yearly, anchor: d(2026, 7, 1)).label == "Yearly on 1 Jul")
        #expect(Recurrence.once(d(2027, 3, 13)).label == "Once on 13 Mar 2027")
        #expect(RecurrenceRule.quarterly.frequencyLabel == "Quarterly")
    }
}

@Suite struct HolidayTests {
    @Test(arguments: [
        (2026, d(2026, 4, 5)), (2027, d(2027, 3, 28)), (2028, d(2028, 4, 16)),
        (2029, d(2029, 4, 1)), (2030, d(2030, 4, 21)), (2019, d(2019, 4, 21)),
    ] as [(Int, LocalDate)])
    func easter(year: Int, expected: LocalDate) {
        #expect(Easter.sunday(in: year) == expected)
    }

    @Test func victoria2026() {
        let dates = VicHolidays.holidays(in: 2026).map(\.date)
        #expect(dates == [
            d(2026, 1, 1), d(2026, 1, 26), d(2026, 3, 9), d(2026, 4, 3), d(2026, 4, 4), d(2026, 4, 5), d(2026, 4, 6),
            d(2026, 4, 25), d(2026, 6, 8), d(2026, 9, 25), d(2026, 11, 3), d(2026, 12, 25), d(2026, 12, 26), d(2026, 12, 28),
        ])
    }

    @Test func victoria2027() {
        let dates = VicHolidays.holidays(in: 2027).map(\.date)
        #expect(dates == [
            d(2027, 1, 1), d(2027, 1, 26), d(2027, 3, 8), d(2027, 3, 26), d(2027, 3, 27), d(2027, 3, 28), d(2027, 3, 29),
            d(2027, 4, 25), d(2027, 6, 14), d(2027, 9, 24), d(2027, 11, 2), d(2027, 12, 25), d(2027, 12, 26),
            d(2027, 12, 27), d(2027, 12, 28),
        ])
    }

    @Test func substituteDaysForWeekendNewYearAndAustraliaDay() {
        // 2028: 1 Jan is a Saturday → Monday 3 Jan; 26 Jan is a Wednesday.
        let y2028 = Set(VicHolidays.holidays(in: 2028).map(\.date))
        #expect(y2028.contains(d(2028, 1, 3)))
        // 2031: 26 Jan is a Sunday → Monday 27 Jan.
        #expect(Set(VicHolidays.holidays(in: 2031).map(\.date)).contains(d(2031, 1, 27)))
        // 2022: Christmas on Sunday → Boxing Day Monday 26, additional Tuesday 27.
        let y2022 = Set(VicHolidays.holidays(in: 2022).map(\.date))
        #expect(y2022.contains(d(2022, 12, 26)) && y2022.contains(d(2022, 12, 27)))
    }

    @Test func calendarExtrasAndRemovals() {
        let calendar = HolidayCalendar(
            extra: [Holiday(date: d(2027, 10, 1), name: "Show Day")],
            removed: [d(2027, 9, 24)]
        )
        #expect(calendar.isHoliday(d(2027, 10, 1)))
        #expect(!calendar.isHoliday(d(2027, 9, 24)))
        #expect(calendar.isHoliday(d(2027, 11, 2)))
        #expect(!calendar.isBusinessDay(d(2027, 10, 2))) // Saturday
        #expect(calendar.isBusinessDay(d(2027, 10, 4)))
        #expect(calendar.holidays(in: DateSpan(d(2027, 12, 20), d(2027, 12, 31))).count == 4)
        #expect(HolidayCalendar.weekendsOnly.isBusinessDay(d(2027, 12, 27)))
        // Outside the precomputed year range still works.
        #expect(calendar.isHoliday(d(2060, 12, 25)))
    }
}
