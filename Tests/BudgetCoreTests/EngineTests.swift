import Foundation
import Testing
@testable import BudgetCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }
private func money(_ text: String) -> Money { Money(parsing: text)! }

private func salaried(
    _ annual: Int64 = 104_000, frequency: RecurrenceRule = .fortnightly, anchor: LocalDate = d(2026, 10, 8),
    offset: Int = 0, start: LocalDate = d(2026, 7, 1), end: LocalDate? = nil, unpaid: [DateSpan] = []
) -> IncomeSource {
    IncomeSource(
        name: "Job", kind: .salaried,
        rates: [RateSegment(from: d(2026, 7, 1), amount: .dollars(annual), unit: .annual)],
        paySchedule: Recurrence(frequency, anchor: anchor), periodEndOffsetDays: offset,
        start: start, end: end, unpaidLeave: unpaid
    )
}

private func run(_ document: BudgetDocument, _ horizon: DateSpan, today: LocalDate = d(2026, 10, 1)) -> Projection {
    ProjectionEngine.run(document: document, today: today, horizon: horizon)
}

private let octToDec = DateSpan(d(2026, 10, 1), d(2026, 12, 31))

@Suite struct IncomeEngineTests {
    @Test func standardPaysAreExact() {
        for (rule, periods) in [(RecurrenceRule.weekly, 52), (.fortnightly, 26), (.monthly, 12)] as [(RecurrenceRule, Int64)] {
            let job = salaried(104_000, frequency: rule)
            let p = run(BudgetDocument(incomes: [job]), octToDec)
            let pay = p.payEvents[1]
            #expect(pay.breakdown.gross == Money.dollars(104_000).scaled(1, periods), "\(rule.frequencyLabel)")
        }
    }

    @Test func fortnightlySalaryNetAndSuper() throws {
        let p = run(BudgetDocument(incomes: [salaried()]), octToDec)
        let pay = try #require(p.payEvents.first)
        #expect(pay.payDate == d(2026, 10, 8))
        #expect(pay.workPeriod == DateSpan(d(2026, 9, 25), d(2026, 10, 8)))
        #expect(pay.breakdown.gross == money("4000"))
        // 4000 / 2 = 2000/wk → x = 2000.99 → 0.32x − 181.7319 = 458.58 → $459 × 2 = $918
        #expect(pay.breakdown.withholding == money("918"))
        #expect(pay.received == money("3082"))
        #expect(pay.breakdown.superGuarantee == money("480"))
    }

    @Test func unpaidLeaveIsProRatedByWorkDays() throws {
        let leave = DateSpan(d(2026, 10, 12), d(2026, 10, 14)) // Mon–Wed
        let p = run(BudgetDocument(incomes: [salaried(unpaid: [leave])]), octToDec)
        let pay = try #require(p.payEvents.first { $0.payDate == d(2026, 10, 22) })
        #expect(pay.unpaidDays == 3)
        #expect(pay.breakdown.gross == money("2800")) // 4000 × 7/10
        #expect(pay.incomeLost == pay.standardBreakdown.net - pay.received)
        #expect(pay.incomeLost.isPositive)
    }

    @Test func jobStartsMidPeriodAndEnds() throws {
        let job = salaried(start: d(2026, 10, 14), end: d(2026, 11, 13))
        let p = run(BudgetDocument(incomes: [job]), octToDec)
        let dates = p.payEvents.map(\.payDate)
        #expect(dates == [d(2026, 10, 22), d(2026, 11, 5), d(2026, 11, 19)])
        // First pay: work period 9–22 Oct, employed from Wed 14th → 7 of 10 days.
        #expect(p.payEvents[0].breakdown.gross == money("2800"))
        // Final pay: 6–19 Nov, employed until Fri 13th → 6 of 10 days.
        #expect(p.payEvents[2].breakdown.gross == money("2400"))
    }

    @Test func payRiseMidPeriodIsProRated() throws {
        var job = salaried()
        IncomeEdits.setRate(RateSegment(from: d(2026, 10, 19), amount: .dollars(130_000), unit: .annual), in: &job)
        let p = run(BudgetDocument(incomes: [job]), octToDec)
        let pay = try #require(p.payEvents.first { $0.payDate == d(2026, 10, 22) })
        // 9–22 Oct: 6 days at $104k (4000/fn) and 4 days at $130k (5000/fn).
        #expect(pay.breakdown.gross == money("4400"))
        #expect(p.payEvents.last!.breakdown.gross == money("5000"))
    }

    @Test func dayRateCountsHolidaysAndOverrides() throws {
        var contract = IncomeSource(
            name: "Contract", kind: .dayRate,
            rates: [RateSegment(from: d(2026, 7, 1), amount: .dollars(800), unit: .daily)],
            paySchedule: Recurrence(.weekly, anchor: d(2026, 11, 4)), periodEndOffsetDays: 3, start: d(2026, 7, 1)
        )
        IncomeEdits.setDaysWorked(250, payDate: d(2026, 11, 11), in: &contract)
        let p = run(BudgetDocument(incomes: [contract]), octToDec)
        let cup = try #require(p.payEvents.first { $0.payDate == d(2026, 11, 11) })
        #expect(cup.workPeriod == DateSpan(d(2026, 11, 2), d(2026, 11, 8)))
        #expect(cup.defaultDaysHundredths == 400) // Melbourne Cup Tuesday is a holiday
        #expect(cup.daysWorkedHundredths == 250)
        #expect(cup.daysOverridden)
        #expect(cup.breakdown.gross == money("2000"))
        let plain = try #require(p.payEvents.first { $0.payDate == d(2026, 11, 18) })
        #expect(plain.breakdown.gross == money("4000"))
        // Melbourne Cup week without an override: 4 days.
        IncomeEdits.setDaysWorked(nil, payDate: d(2026, 11, 11), in: &contract)
        let p2 = run(BudgetDocument(incomes: [contract]), octToDec)
        #expect(p2.payEvents.first { $0.payDate == d(2026, 11, 11) }?.breakdown.gross == money("3200"))
    }

    @Test func payDayOnHolidayMovesEarlierButKeepsWorkPeriod() throws {
        let job = salaried(frequency: .monthly, anchor: d(2026, 12, 26), offset: 0)
        let p = run(BudgetDocument(incomes: [job]), octToDec)
        let pay = try #require(p.payEvents.first { $0.originalDate == d(2026, 12, 26) })
        #expect(pay.payDate == d(2026, 12, 24)) // Sat Boxing Day → Thu 24th
        #expect(pay.workPeriod == DateSpan(d(2026, 11, 27), d(2026, 12, 26)))
    }

    @Test func missedPayAndActualNetOverrides() throws {
        var job = salaried()
        IncomeEdits.setOverride(OccurrenceOverride(originalDate: d(2026, 10, 22), skip: true), in: &job)
        IncomeEdits.setOverride(OccurrenceOverride(originalDate: d(2026, 11, 5), amount: money("3100.50")), in: &job)
        let p = run(BudgetDocument(incomes: [job]), octToDec)
        let missed = try #require(p.payEvents.first { $0.originalDate == d(2026, 10, 22) })
        #expect(missed.state == .skipped)
        #expect(missed.received == .zero)
        #expect(missed.incomeLost == money("3082"))
        let actual = try #require(p.payEvents.first { $0.originalDate == d(2026, 11, 5) })
        #expect(actual.received == money("3100.50"))
        let flow = try #require(p.flow(OccurrenceKey(sourceID: job.id, originalDate: d(2026, 11, 5))))
        #expect(flow.amount == money("3100.50"))
        #expect(flow.isOverridden)
    }

    @Test func abnSetAsidesCoverTheYearsTax() throws {
        let abn = IncomeSource(
            name: "Consulting", kind: .abn,
            rates: [RateSegment(from: d(2026, 7, 1), amount: .dollars(1000), unit: .daily)],
            paySchedule: Recurrence(.weekly, anchor: d(2026, 7, 3)), periodEndOffsetDays: 5,
            gstRegistered: true, start: d(2026, 7, 1)
        )
        let p = run(BudgetDocument(settings: Settings(applyStandardDeduction: false), incomes: [abn]), octToDec)
        let estimate = try #require(p.estimates.first { $0.year == FinancialYear(startYear: 2026) })
        let setAside = estimate.setAside
        #expect(abs((setAside - estimate.tax.total).cents) <= Int64(estimate.payCount)) // shares round to cents
        let pay = try #require(p.payEvents.first { $0.payDate == d(2026, 10, 9) })
        #expect(pay.breakdown.gst == money("500"))
        #expect(pay.received == money("5500"))
        #expect(pay.breakdown.taxSetAside.isPositive)
        let flows = p.flows.filter { $0.key.sourceID == abn.id && $0.date == d(2026, 10, 9) }
        #expect(flows.map(\.kind) == [.pay, .taxSetAside, .gstSetAside])
        #expect(flows[2].amount == money("-500"))
        let grid = GridBuilder.build(p, document: BudgetDocument(incomes: [abn]), granularity: .week)
        #expect(grid.sections.map(\.title).contains("Set aside"))
    }

    @Test func secondJobUsesScaleOneAndYearEstimateAddsUp() throws {
        var second = salaried(26_000, frequency: .weekly, anchor: d(2026, 10, 2))
        second.claimsTaxFreeThreshold = false
        let p = run(BudgetDocument(incomes: [salaried(), second]), octToDec)
        let weekly = try #require(p.payEvents.first { $0.sourceID == second.id })
        // $500/wk on scale 1: 0.179 × 500.99 − 0.1066 = 89.57 → $90
        #expect(weekly.breakdown.withholding == money("90"))
        let year = try #require(p.estimates.first)
        #expect(year.grossIncome.isPositive)
        #expect(year.taxableIncome == year.grossIncome - year.standardDeduction)
    }
}

@Suite struct ItemProjectionTests {
    @Test func overridesSkipAndMove() throws {
        var rent = BudgetItem(name: "Rent", segments: [ScheduleSegment(start: d(2026, 7, 1), recurrence: Recurrence(.monthly, anchor: d(2026, 7, 1)), amount: .dollars(2000))])
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2026, 11, 1), skip: true), in: &rent)
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 2, 1), movedTo: d(2026, 12, 20)), in: &rent)
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2026, 12, 1), amount: .dollars(2100)), in: &rent)
        let p = run(BudgetDocument(items: [rent]), octToDec)
        let flows = p.flows
        #expect(flows.map(\.date) == [d(2026, 10, 1), d(2026, 11, 1), d(2026, 12, 1), d(2026, 12, 20)])
        #expect(flows[1].state == .skipped && flows[1].amount == .zero)
        #expect(flows[2].amount == money("-2100"))
        #expect(flows[3].key.originalDate == d(2027, 2, 1)) // moved in from outside the horizon
    }

    @Test func periodLinesOnlyHappenInsideTheirPeriod() {
        let trip = Period(name: "Trip", span: DateSpan(d(2026, 11, 4), d(2026, 11, 20)))
        let line = BudgetItem(name: "Trip spending", segments: [ScheduleSegment(start: d(2026, 1, 1), recurrence: Recurrence(.weekly, anchor: d(2026, 10, 5)), amount: .dollars(400))], periodID: trip.id)
        let p = run(BudgetDocument(items: [line], periods: [trip]), octToDec)
        #expect(p.flows.map(\.date) == [d(2026, 11, 9), d(2026, 11, 16)])
    }

    @Test func checkpointBeforeTheWindowCarriesIn() throws {
        let rent = BudgetItem(name: "Rent", segments: [ScheduleSegment(start: d(2026, 1, 1), recurrence: Recurrence(.monthly, anchor: d(2026, 1, 1)), amount: .dollars(1000))])
        let doc = BudgetDocument(items: [rent], checkpoints: [BalanceCheckpoint(date: d(2026, 8, 15), amount: .dollars(5000))])
        let p = run(doc, octToDec)
        // Sep 1 and Oct 1 rent have been paid since the checkpoint.
        #expect(p.days.first?.opening == money("4000"))
        #expect(p.days.first?.closing == money("3000"))
        #expect(p.ledger(on: d(2026, 12, 31))?.closing == money("1000"))
    }
}

@Suite struct EnvelopeTests {
    private func envelope(_ dollars: Int64, _ rule: RecurrenceRule, anchor: LocalDate) -> BudgetItem {
        BudgetItem(name: "Food", envelope: EnvelopeRule(categoryIDs: ["groceries"]),
                   segments: [ScheduleSegment(start: d(2026, 1, 1), recurrence: Recurrence(rule, anchor: anchor), amount: .dollars(dollars))])
    }

    @Test func weeklyBudgetSpreadsCentsExactly() throws {
        let p = run(BudgetDocument(items: [envelope(300, .weekly, anchor: d(2026, 10, 5))]), DateSpan(d(2026, 10, 5), d(2026, 10, 11)))
        let period = try #require(p.envelopes.first)
        #expect(period.allocations.map(\.amount.cents) == [4286, 4286, 4286, 4286, 4286, 4285, 4285])
        #expect(p.days.reduce(Money.zero) { $0 + $1.outflow } == money("300"))
    }

    @Test(arguments: [(2027, 2, 28), (2026, 11, 30), (2026, 12, 31)] as [(Int, Int, Int)])
    func monthlyBudgetMatchesMonthLength(year: Int, month: Int, days: Int) throws {
        let span = DateSpan(LocalDate(year, month, 1), LocalDate(year, month, days))
        let p = run(BudgetDocument(items: [envelope(620, .monthly, anchor: d(2026, 1, 1))]), span)
        let period = try #require(p.envelopes.first)
        #expect(period.allocations.count == days)
        #expect(period.allocations.reduce(Money.zero) { $0 + $1.amount } == money("620"))
    }

    @Test func pausedDaysReduceTheBudgetProRata() throws {
        let food = envelope(350, .weekly, anchor: d(2026, 10, 5))
        let trip = Period(name: "Trip", span: DateSpan(d(2026, 10, 8), d(2026, 10, 11)), pausedItemIDs: [food.id])
        let p = run(BudgetDocument(items: [food], periods: [trip]), DateSpan(d(2026, 10, 5), d(2026, 10, 18)))
        #expect(p.envelopes[0].budget == money("150"))      // 3 of 7 days
        #expect(p.envelopes[0].allocations.count == 3)
        #expect(p.envelopes[1].budget == money("350"))
    }

    @Test func horizonCuttingAPeriodKeepsDailyRates() throws {
        let p = run(BudgetDocument(items: [envelope(70, .weekly, anchor: d(2026, 10, 5))]), DateSpan(d(2026, 10, 8), d(2026, 10, 14)))
        #expect(p.days.allSatisfy { $0.outflow == money("10") })
    }
}
