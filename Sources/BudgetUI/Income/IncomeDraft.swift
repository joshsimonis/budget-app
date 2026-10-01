import BudgetCore
import Foundation

enum PayFrequencyChoice: String, CaseIterable, Identifiable {
    case weekly, fortnightly, fourWeekly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly: "Weekly"
        case .fortnightly: "Fortnightly"
        case .fourWeekly: "Every 4 weeks"
        case .monthly: "Monthly"
        }
    }

    var rule: RecurrenceRule {
        switch self {
        case .weekly: .weekly
        case .fortnightly: .fortnightly
        case .fourWeekly: .fourWeekly
        case .monthly: .monthly
        }
    }

    var payFrequency: PayFrequency {
        switch self {
        case .weekly: .weekly
        case .fortnightly: .fortnightly
        case .fourWeekly: .fourWeekly
        case .monthly: .monthly
        }
    }

    static func from(_ rule: RecurrenceRule) -> PayFrequencyChoice {
        switch (rule.unit, rule.interval) {
        case (.week, 2): .fortnightly
        case (.week, 4): .fourWeekly
        case (.month, _): .monthly
        default: .weekly
        }
    }
}

/// Editable copy of an income source.
struct IncomeDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var source: IncomeSource
    var currentRateID: UUID?

    var rateAmount: Money
    var rateUnit: RateUnit
    var superMode: SuperMode
    var frequency: PayFrequencyChoice
    var nextPay: LocalDate
    var hasEnd: Bool
    var end: LocalDate
    var patterns: String
    var setAsidePercent: Money // as a number, e.g. 30.00

    init(newKind kind: EmploymentKind, today: LocalDate, accountID: UUID?) {
        id = UUID()
        isNew = true
        let firstPay = today.adding(days: IntMath.floorMod(Weekday.thursday.rawValue - today.weekday.rawValue, 7))
        source = IncomeSource(
            id: id,
            name: "",
            kind: kind,
            rates: [],
            paySchedule: Recurrence(kind == .salaried ? .fortnightly : .weekly, anchor: firstPay),
            periodEndOffsetDays: kind == .salaried ? 0 : 3,
            start: today.startOfWeek.adding(days: -56),
            accountID: accountID
        )
        currentRateID = nil
        switch kind {
        case .salaried:
            rateAmount = .dollars(90_000)
            rateUnit = .annual
        case .dayRate, .abn:
            rateAmount = .dollars(700)
            rateUnit = .daily
        }
        superMode = .onTop
        frequency = kind == .salaried ? .fortnightly : .weekly
        nextPay = firstPay
        hasEnd = false
        end = today.adding(months: 12)
        patterns = ""
        setAsidePercent = Money(cents: 3000)
    }

    init(source: IncomeSource, today: LocalDate) {
        id = source.id
        isNew = false
        self.source = source
        let rate = source.rate(on: today)
        currentRateID = rate?.id
        rateAmount = rate?.amount ?? .zero
        rateUnit = rate?.unit ?? .annual
        superMode = rate?.superMode ?? .onTop
        frequency = PayFrequencyChoice.from(source.paySchedule.rule)
        nextPay = source.paySchedule.next(onOrAfter: today) ?? source.paySchedule.anchor
        hasEnd = source.end != nil
        end = source.end ?? today.adding(months: 12)
        patterns = source.match?.patterns.joined(separator: ", ") ?? ""
        setAsidePercent = Money(cents: Int64(source.setAsidePercentBasisPoints))
    }

    var isValid: Bool {
        !source.name.trimmingCharacters(in: .whitespaces).isEmpty && rateAmount.isPositive && (!hasEnd || end >= source.start)
    }

    mutating func addRate(from date: LocalDate, amount: Money) {
        commitRate()
        IncomeEdits.setRate(RateSegment(from: date, amount: amount, unit: rateUnit, superMode: superMode), in: &source)
    }

    mutating func removeRate(_ id: UUID) {
        IncomeEdits.removeRate(id: id, in: &source)
        if currentRateID == id { currentRateID = source.rates.last?.id }
    }

    mutating func addLeave(_ span: DateSpan) {
        source.unpaidLeave.append(span)
        source.unpaidLeave.sort { $0.start < $1.start }
    }

    /// Writes the rate fields into the current rate segment (or creates the first one).
    private mutating func commitRate() {
        if let index = source.rates.firstIndex(where: { $0.id == currentRateID }) {
            source.rates[index].amount = rateAmount
            source.rates[index].unit = rateUnit
            source.rates[index].superMode = superMode
        } else if source.rates.isEmpty {
            let rate = RateSegment(from: source.start, amount: rateAmount, unit: rateUnit, superMode: superMode)
            source.rates = [rate]
            currentRateID = rate.id
        }
    }

    func build() -> IncomeSource {
        var draft = self
        draft.commitRate()
        var result = draft.source
        result.name = result.name.trimmingCharacters(in: .whitespaces)
        let schedule = Recurrence(frequency.rule, anchor: nextPay)
        if result.paySchedule.rule != schedule.rule || !result.paySchedule.isOccurrence(nextPay) {
            result.paySchedule = schedule
        }
        result.end = hasEnd ? end : nil
        result.setAsidePercentBasisPoints = Int(setAsidePercent.cents)
        let list = patterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result.match = list.isEmpty ? nil : MatchRule(patterns: list)
        if result.kind == .abn { result.claimsTaxFreeThreshold = true }
        IncomeEdits.removeOrphans(in: &result)
        return result
    }

    /// A pay quote for the current rate, for the live preview.
    func quote(applyStandardDeduction: Bool, year: FinancialYear) -> PayQuote {
        let sacrificePerYear = source.salarySacrificePerPay * frequency.payFrequency.periodsPerYear
        let afterTaxPerYear = source.afterTaxSuperPerPay * frequency.payFrequency.periodsPerYear
        return PayQuote.make(PayQuoteInput(
            amount: rateAmount,
            unit: rateUnit,
            superMode: superMode,
            kind: source.kind,
            workDaysPerWeek: max(1, source.workDays.count),
            claimsTaxFreeThreshold: source.claimsTaxFreeThreshold,
            salarySacrificePerYear: sacrificePerYear,
            afterTaxSuperPerYear: afterTaxPerYear,
            gstRegistered: source.gstRegistered,
            applyStandardDeduction: applyStandardDeduction,
            year: year
        ))
    }
}
