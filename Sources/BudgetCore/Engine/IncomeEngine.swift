import Foundation

/// One pay from an income source, fully worked out.
public struct PayEvent: Hashable, Sendable, Identifiable {
    public var sourceID: UUID
    public var sourceName: String
    public var kind: EmploymentKind
    /// The scheduled pay date (identity).
    public var originalDate: LocalDate
    /// When the money lands (after weekend/holiday adjustment or a move).
    public var payDate: LocalDate
    /// The days this pay covers.
    public var workPeriod: DateSpan
    public var frequency: PayFrequency?
    /// Day-rate and ABN: days paid, in hundredths.
    public var daysWorkedHundredths: Int?
    /// Day-rate and ABN: the default days (work days minus public holidays and unpaid days).
    public var defaultDaysHundredths: Int?
    public var daysOverridden: Bool
    /// Work days lost to unpaid leave or unpaid periods.
    public var unpaidDays: Int
    public var breakdown: PayBreakdown
    /// The same pay with no unpaid leave or missed pay, to show income lost.
    public var standardBreakdown: PayBreakdown
    public var state: FlowState
    /// The net amount you said you actually got (overrides the calculation).
    public var netOverride: Money?
    public var isMoved: Bool
    public var year: FinancialYear

    public var id: OccurrenceKey { OccurrenceKey(sourceID: sourceID, originalDate: originalDate) }

    /// Cash expected in your account.
    public var received: Money {
        state == .skipped ? .zero : (netOverride ?? breakdown.net)
    }

    /// How much less this pay is than a normal one (unpaid leave, fewer days, missed pay).
    public var incomeLost: Money {
        max(.zero, standardBreakdown.net - received)
    }
}

/// A financial year's tax position from the planned pays.
public struct AnnualTaxEstimate: Hashable, Sendable, Identifiable {
    public var year: FinancialYear
    public var payCount: Int
    public var grossIncome: Money
    public var preTaxContributions: Money
    public var standardDeduction: Money
    public var taxableIncome: Money
    public var tax: TaxComputation
    public var withheld: Money
    /// ABN income tax planned to be set aside.
    public var setAside: Money
    public var superGuarantee: Money
    public var concessionalCap: Money
    public var isEstimate: Bool
    public var notes: [String]

    public var id: Int { year.startYear }
    public var concessionalContributions: Money { superGuarantee + preTaxContributions }
    public var exceedsConcessionalCap: Bool { concessionalContributions > concessionalCap }
    /// Withheld + set aside − tax owed. Positive: refund (or spare set-aside). Negative: a bill.
    public var position: Money { withheld + setAside - tax.total }
}

public struct IncomeResult: Sendable {
    /// Pays landing inside the horizon.
    public var events: [PayEvent]
    /// Pay and set-aside flows inside the horizon.
    public var flows: [PlannedFlow]
    /// One per financial year the horizon touches (that has pays).
    public var estimates: [AnnualTaxEstimate]
}

public enum IncomeEngine {
    public static func run(context: PlanContext) -> IncomeResult {
        let firstYear = context.horizon.start.financialYear
        let lastYear = context.horizon.end.financialYear
        let span = DateSpan(start: firstYear.start, end: lastYear.end)

        var all: [PayEvent] = []
        for source in context.document.incomes where !source.archived {
            all += payEvents(for: source, context: context, span: span)
        }
        applySetAsides(to: &all, context: context)

        var estimates: [AnnualTaxEstimate] = []
        for startYear in firstYear.startYear...lastYear.startYear {
            let year = FinancialYear(startYear: startYear)
            if let estimate = estimate(for: year, events: all, settings: context.settings) {
                estimates.append(estimate)
            }
        }

        let sources = Dictionary(uniqueKeysWithValues: context.document.incomes.map { ($0.id, $0) })
        let inHorizon = all.filter { context.horizon.contains($0.payDate) }.sorted { ($0.payDate, $0.id) < ($1.payDate, $1.id) }
        let payFlows = inHorizon.flatMap { event in
            sources[event.sourceID].map { IncomeEngine.flows(for: event, source: $0) } ?? []
        }
        return IncomeResult(events: inHorizon, flows: payFlows, estimates: estimates)
    }

    /// Pays for one source whose pay date falls in `span` (before set-asides are worked out).
    public static func payEvents(for source: IncomeSource, context: PlanContext, span: DateSpan) -> [PayEvent] {
        let schedule = source.paySchedule
        guard schedule.rule.unit != .once, !source.rates.isEmpty else { return [] }
        let frequency = PayFrequency.from(schedule.rule)
        let unpaid = context.unpaidSpans(for: source)
        let workDays = Set(source.workDays)
        var superBaseUsed: [FinancialYear: Money] = [:]
        var events: [PayEvent] = []

        func isUnpaid(_ date: LocalDate) -> Bool { unpaid.contains { $0.contains(date) } }

        for original in schedule.originalDates(in: span.expanded(by: 14)) {
            guard let k = schedule.index(onOrBefore: original) else { continue }
            let previous = schedule.date(at: k - 1)
            let workEnd = original.adding(days: -source.periodEndOffsetDays)
            let workStart = previous.adding(days: 1 - source.periodEndOffsetDays)
            guard workStart <= workEnd else { continue }
            let workPeriod = DateSpan(start: workStart, end: workEnd)
            guard source.start <= workEnd, source.end.map({ $0 >= workStart }) ?? true else { continue }

            let override = source.override(for: original)
            let payDate = override?.movedTo ?? context.calendar.adjust(original, context.settings.payDayAdjustment)
            guard span.contains(payDate) else { continue }
            let data = TaxTables.data(for: payDate)
            let year = payDate.financialYear

            var actual = gross(for: source, workPeriod: workPeriod, frequency: frequency, workDays: workDays,
                               includeUnpaidDays: false, isUnpaid: isUnpaid, context: context, data: data)
            let standard = gross(for: source, workPeriod: workPeriod, frequency: frequency, workDays: workDays,
                                 includeUnpaidDays: true, isUnpaid: isUnpaid, context: context, data: data)

            var daysOverridden = false
            if source.kind != .salaried, let days = source.daysWorkedOverride(for: original) {
                daysOverridden = true
                let lastDay = min(workEnd, source.end ?? workEnd)
                if let rate = source.rate(on: lastDay) {
                    let daily = RateMath.dailyBase(rate, kind: source.kind, workDaysPerWeek: workDays.count, data: data)
                    actual.gross = daily.scaled(Int64(days.hundredths), 100)
                    actual.daysHundredths = days.hundredths
                }
            }

            let used = superBaseUsed[year] ?? .zero
            let superBase = min(actual.gross, max(.zero, data.maxContributionBase - used))
            superBaseUsed[year] = used + superBase

            let breakdown = makeBreakdown(source: source, gross: actual.gross, frequency: frequency,
                                          periodDays: workPeriod.dayCount, superBase: superBase, data: data)
            let standardBreakdown = makeBreakdown(source: source, gross: standard.gross, frequency: frequency,
                                                  periodDays: workPeriod.dayCount, superBase: standard.gross, data: data)

            let state: FlowState
            if override?.skip == true {
                state = .skipped
            } else if actual.gross.isZero && override?.amount == nil {
                state = .unpaid
            } else {
                state = .planned
            }

            events.append(PayEvent(
                sourceID: source.id,
                sourceName: source.name,
                kind: source.kind,
                originalDate: original,
                payDate: payDate,
                workPeriod: workPeriod,
                frequency: frequency,
                daysWorkedHundredths: source.kind == .salaried ? nil : actual.daysHundredths,
                defaultDaysHundredths: source.kind == .salaried ? nil : actual.defaultDaysHundredths,
                daysOverridden: daysOverridden,
                unpaidDays: actual.unpaidDays,
                breakdown: breakdown,
                standardBreakdown: standardBreakdown,
                state: state,
                netOverride: override?.amount,
                isMoved: override?.movedTo != nil,
                year: year
            ))
        }
        return events
    }

    private struct GrossResult {
        var gross: Money
        var daysHundredths: Int?
        var defaultDaysHundredths: Int?
        var unpaidDays: Int
    }

    private static func gross(
        for source: IncomeSource, workPeriod: DateSpan, frequency: PayFrequency?, workDays: Set<Weekday>,
        includeUnpaidDays: Bool, isUnpaid: (LocalDate) -> Bool, context: PlanContext, data: TaxYearData
    ) -> GrossResult {
        let periodWorkDays = workPeriod.dates.filter { workDays.contains($0.weekday) }
        var unpaidDays = 0

        switch source.kind {
        case .salaried:
            // Public holidays are paid; pro-rate by work days for part periods and unpaid leave.
            guard !periodWorkDays.isEmpty else { return GrossResult(gross: .zero, unpaidDays: 0) }
            var daysByRate: [UUID: (RateSegment, Int)] = [:]
            for date in periodWorkDays where source.isEmployed(on: date) {
                if isUnpaid(date) {
                    unpaidDays += 1
                    if !includeUnpaidDays { continue }
                }
                guard let rate = source.rate(on: date) else { continue }
                daysByRate[rate.id, default: (rate, 0)].1 += 1
            }
            var total = Money.zero
            for (rate, days) in daysByRate.values.sorted(by: { $0.0.from < $1.0.from }) {
                let annual = RateMath.annualBase(rate, kind: .salaried, workDaysPerWeek: workDays.count, data: data)
                let perPay: Money
                if let frequency {
                    perPay = annual.scaled(1, Int64(frequency.periodsPerYear))
                } else {
                    perPay = annual.scaled(Int64(workPeriod.dayCount), 365)
                }
                total += perPay.scaled(Int64(days), Int64(periodWorkDays.count))
            }
            return GrossResult(gross: total, unpaidDays: unpaidDays)

        case .dayRate, .abn:
            // Paid for each work day that isn't a public holiday, unpaid, or outside employment.
            var total = Money.zero
            var days = 0
            for date in periodWorkDays where source.isEmployed(on: date) && !context.calendar.isHoliday(date) {
                if isUnpaid(date) {
                    unpaidDays += 1
                    if !includeUnpaidDays { continue }
                }
                guard let rate = source.rate(on: date) else { continue }
                total += RateMath.dailyBase(rate, kind: source.kind, workDaysPerWeek: workDays.count, data: data)
                days += 1
            }
            return GrossResult(gross: total, daysHundredths: days * 100, defaultDaysHundredths: days * 100, unpaidDays: unpaidDays)
        }
    }

    private static func makeBreakdown(
        source: IncomeSource, gross: Money, frequency: PayFrequency?, periodDays: Int, superBase: Money, data: TaxYearData
    ) -> PayBreakdown {
        guard gross.isPositive else { return PayBreakdown(kind: source.kind, usesEstimatedTables: data.isEstimate) }
        if source.kind == .abn {
            return PayCalculator.abn(fee: gross, gstRegistered: source.gstRegistered, contribution: source.salarySacrificePerPay)
        }
        return PayCalculator.payroll(
            kind: source.kind,
            gross: gross,
            frequency: frequency,
            periodDays: periodDays,
            claimsTaxFreeThreshold: source.claimsTaxFreeThreshold,
            salarySacrifice: source.salarySacrificePerPay,
            afterTaxSuper: source.afterTaxSuperPerPay,
            superBase: superBase,
            data: data
        )
    }

    /// Works out ABN income-tax set-asides. In estimate mode each payment carries its share
    /// of the year's tax that payroll withholding won't cover.
    static func applySetAsides(to events: inout [PayEvent], context: PlanContext) {
        let modes = Dictionary(uniqueKeysWithValues: context.document.incomes.map { ($0.id, ($0.setAsideMode, $0.setAsidePercentBasisPoints)) })
        let years = Set(events.filter { $0.kind == .abn }.map(\.year))
        for year in years {
            let counted = events.indices.filter { events[$0].year == year && events[$0].state != .skipped }
            let data = TaxTables.data(for: year)
            let taxable = counted.reduce(Money.zero) { $0 + events[$1].breakdown.taxable }
            let deduction = context.settings.applyStandardDeduction ? data.standardDeduction : .zero
            let liability = AnnualTax.compute(taxableIncome: max(.zero, taxable - deduction), data: data).total
            let withheld = counted.reduce(Money.zero) { $0 + events[$1].breakdown.withholding }
            let shortfall = max(.zero, liability - withheld)
            let abn = counted.filter { events[$0].kind == .abn }
            let fees = abn.reduce(Money.zero) { $0 + events[$1].breakdown.gross }
            for index in abn {
                let fee = events[index].breakdown.gross
                let (mode, basisPoints) = modes[events[index].sourceID] ?? (.estimate, 0)
                switch mode {
                case .estimate:
                    events[index].breakdown.taxSetAside = fees.isPositive ? shortfall.scaled(fee.cents, fees.cents) : .zero
                case .percent:
                    events[index].breakdown.taxSetAside = fee.percent(basisPoints: basisPoints)
                case .none:
                    events[index].breakdown.taxSetAside = .zero
                }
            }
        }
    }

    static func estimate(for year: FinancialYear, events: [PayEvent], settings: Settings) -> AnnualTaxEstimate? {
        let counted = events.filter { $0.year == year && $0.state != .skipped }
        guard !counted.isEmpty else { return nil }
        let data = TaxTables.data(for: year)
        let gross = counted.reduce(Money.zero) { $0 + $1.breakdown.gross }
        let contributions = counted.reduce(Money.zero) { $0 + $1.breakdown.salarySacrifice }
        let deduction = settings.applyStandardDeduction ? data.standardDeduction : .zero
        let taxable = max(.zero, gross - contributions - deduction)
        return AnnualTaxEstimate(
            year: year,
            payCount: counted.count,
            grossIncome: gross,
            preTaxContributions: contributions,
            standardDeduction: deduction,
            taxableIncome: taxable,
            tax: AnnualTax.compute(taxableIncome: taxable, data: data),
            withheld: counted.reduce(Money.zero) { $0 + $1.breakdown.withholding },
            setAside: counted.reduce(Money.zero) { $0 + $1.breakdown.taxSetAside },
            superGuarantee: counted.reduce(Money.zero) { $0 + $1.breakdown.superGuarantee },
            concessionalCap: data.concessionalCap,
            isEstimate: data.isEstimate,
            notes: data.notes
        )
    }

    /// The pay itself plus any ABN set-asides, as planned flows.
    public static func flows(for event: PayEvent, source: IncomeSource) -> [PlannedFlow] {
        let planned = event.state == .planned ? event.received : event.standardBreakdown.net
        var flows = [PlannedFlow(
            key: event.id,
            kind: .pay,
            name: source.name,
            date: event.payDate,
            amount: event.state == .planned ? event.received : .zero,
            plannedAmount: planned,
            accountID: source.accountID,
            state: event.state,
            isOverridden: event.netOverride != nil || event.daysOverridden || event.isMoved,
            periodID: nil
        )]
        guard event.state == .planned else { return flows }
        if event.breakdown.taxSetAside.isPositive {
            flows.append(PlannedFlow(
                key: OccurrenceKey(sourceID: source.id, originalDate: event.originalDate, part: .taxSetAside),
                kind: .taxSetAside,
                name: "Tax set-aside: \(source.name)",
                date: event.payDate,
                amount: -event.breakdown.taxSetAside,
                plannedAmount: -event.breakdown.taxSetAside,
                accountID: source.accountID,
                state: .planned,
                isOverridden: false,
                periodID: nil
            ))
        }
        if event.breakdown.gstSetAside.isPositive {
            flows.append(PlannedFlow(
                key: OccurrenceKey(sourceID: source.id, originalDate: event.originalDate, part: .gstSetAside),
                kind: .gstSetAside,
                name: "GST set-aside: \(source.name)",
                date: event.payDate,
                amount: -event.breakdown.gstSetAside,
                plannedAmount: -event.breakdown.gstSetAside,
                accountID: source.accountID,
                state: .planned,
                isOverridden: false,
                periodID: nil
            ))
        }
        return flows
    }
}
