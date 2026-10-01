import Foundation

public enum EmploymentKind: String, Codable, Sendable, CaseIterable {
    /// Salary through payroll (PAYG withholding).
    case salaried
    /// Paid per day worked through payroll or an umbrella company (PAYG withholding).
    case dayRate
    /// Invoices under an ABN; no withholding, so tax (and GST) is set aside.
    case abn

    public var label: String {
        switch self {
        case .salaried: "Salaried (PAYG)"
        case .dayRate: "Day rate (payroll)"
        case .abn: "ABN contractor"
        }
    }
}

/// The unit a pay rate is quoted in.
public enum RateUnit: String, Codable, Sendable, CaseIterable {
    case annual, monthly, fortnightly, weekly, daily

    public var label: String {
        switch self {
        case .annual: "per year"
        case .monthly: "per month"
        case .fortnightly: "per fortnight"
        case .weekly: "per week"
        case .daily: "per day"
        }
    }
}

/// Whether a quoted rate already includes the super guarantee ("package") or super is on top.
public enum SuperMode: String, Codable, Sendable, CaseIterable {
    case onTop, included

    public var label: String { self == .onTop ? "plus super" : "including super" }
}

/// How an ABN contractor's income tax is put aside.
public enum SetAsideMode: String, Codable, Sendable, CaseIterable {
    /// The payment's share of the year's estimated tax.
    case estimate
    /// A fixed percentage of each payment.
    case percent
    /// Don't plan a set-aside.
    case none
}

/// A pay rate that applies from a date until the next rate (a pay rise is a new segment).
public struct RateSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var from: LocalDate
    public var amount: Money
    public var unit: RateUnit
    public var superMode: SuperMode

    public init(id: UUID = UUID(), from: LocalDate, amount: Money, unit: RateUnit, superMode: SuperMode = .onTop) {
        self.id = id
        self.from = from
        self.amount = amount
        self.unit = unit
        self.superMode = superMode
    }
}

/// Days actually worked for one pay (day-rate and ABN sources), in hundredths of a day.
public struct DaysWorked: Hashable, Codable, Sendable {
    /// The pay's original (unadjusted) pay date.
    public var payDate: LocalDate
    /// 450 = 4.5 days.
    public var hundredths: Int

    public init(payDate: LocalDate, hundredths: Int) {
        self.payDate = payDate
        self.hundredths = hundredths
    }
}

/// A job or contract that pays you.
public struct IncomeSource: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: EmploymentKind
    /// Sorted by `from`. Each applies until the next.
    public var rates: [RateSegment]
    /// When pay lands (weekly, fortnightly, monthly…), before business-day adjustment.
    public var paySchedule: Recurrence
    /// The work period a pay covers ends this many days before the (unadjusted) pay date.
    /// 0 = paid up to and including payday; 3 = Wednesday pay for the week ending Sunday.
    public var periodEndOffsetDays: Int
    public var workDays: [Weekday]
    /// Scale 2 if true, Scale 1 (e.g. a second job) if false.
    public var claimsTaxFreeThreshold: Bool
    /// Pre-tax salary sacrifice to super each pay. For ABN: a personal deductible contribution.
    public var salarySacrificePerPay: Money
    /// After-tax super contribution each pay.
    public var afterTaxSuperPerPay: Money
    public var gstRegistered: Bool
    public var setAsideMode: SetAsideMode
    /// Used when `setAsideMode == .percent` (3000 = 30%).
    public var setAsidePercentBasisPoints: Int
    public var start: LocalDate
    /// Last day of employment; nil = ongoing.
    public var end: LocalDate?
    public var daysWorked: [DaysWorked]
    public var unpaidLeave: [DateSpan]
    /// Per-pay changes keyed by original pay date: skip = missed pay, amount = actual net received.
    public var overrides: [OccurrenceOverride]
    public var accountID: UUID?
    public var match: MatchRule?
    public var sortIndex: Int
    public var archived: Bool
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: EmploymentKind,
        rates: [RateSegment],
        paySchedule: Recurrence,
        periodEndOffsetDays: Int = 0,
        workDays: [Weekday] = Weekday.weekdays,
        claimsTaxFreeThreshold: Bool = true,
        salarySacrificePerPay: Money = .zero,
        afterTaxSuperPerPay: Money = .zero,
        gstRegistered: Bool = false,
        setAsideMode: SetAsideMode = .estimate,
        setAsidePercentBasisPoints: Int = 3000,
        start: LocalDate,
        end: LocalDate? = nil,
        daysWorked: [DaysWorked] = [],
        unpaidLeave: [DateSpan] = [],
        overrides: [OccurrenceOverride] = [],
        accountID: UUID? = nil,
        match: MatchRule? = nil,
        sortIndex: Int = 0,
        archived: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rates = rates.sorted { $0.from < $1.from }
        self.paySchedule = paySchedule
        self.periodEndOffsetDays = periodEndOffsetDays
        self.workDays = workDays
        self.claimsTaxFreeThreshold = claimsTaxFreeThreshold
        self.salarySacrificePerPay = salarySacrificePerPay
        self.afterTaxSuperPerPay = afterTaxSuperPerPay
        self.gstRegistered = gstRegistered
        self.setAsideMode = setAsideMode
        self.setAsidePercentBasisPoints = setAsidePercentBasisPoints
        self.start = start
        self.end = end
        self.daysWorked = daysWorked
        self.unpaidLeave = unpaidLeave
        self.overrides = overrides
        self.accountID = accountID
        self.match = match
        self.sortIndex = sortIndex
        self.archived = archived
        self.notes = notes
    }

    /// The rate in force on `date` (the last segment starting on or before it).
    public func rate(on date: LocalDate) -> RateSegment? {
        rates.last { $0.from <= date } ?? rates.first
    }

    public var employment: DateSpan? {
        DateSpan.make(start, end ?? LocalDate(9999, 12, 31))
    }

    public func isEmployed(on date: LocalDate) -> Bool {
        date >= start && (end.map { date <= $0 } ?? true)
    }

    public func daysWorkedOverride(for payDate: LocalDate) -> DaysWorked? {
        daysWorked.first { $0.payDate == payDate }
    }

    public func override(for payDate: LocalDate) -> OccurrenceOverride? {
        overrides.first { $0.originalDate == payDate }
    }
}
