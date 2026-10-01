import Foundation

/// Shared inputs for one projection run.
public struct PlanContext: Sendable {
    public let document: BudgetDocument
    public let calendar: HolidayCalendar
    public let today: LocalDate
    public let horizon: DateSpan

    public init(document: BudgetDocument, today: LocalDate, horizon: DateSpan? = nil, calendar: HolidayCalendar? = nil) {
        self.document = document
        self.today = today
        self.horizon = horizon ?? PlanContext.defaultHorizon(settings: document.settings, today: today)
        self.calendar = calendar ?? document.settings.makeHolidayCalendar()
    }

    /// From `historyWeeks` before this week's Monday to the end of the month `horizonMonths` ahead.
    public static func defaultHorizon(settings: Settings, today: LocalDate) -> DateSpan {
        let start = today.startOfWeek.adding(days: -7 * max(0, settings.historyWeeks))
        let end = today.adding(months: max(1, settings.horizonMonths)).endOfMonth
        return DateSpan(start: start, end: end)
    }

    public var settings: Settings { document.settings }

    /// Whether a period pauses this item on `date`.
    public func isPaused(_ itemID: UUID, on date: LocalDate) -> Bool {
        document.periods.contains { $0.span.contains(date) && $0.pausedItemIDs.contains(itemID) }
    }

    /// Date ranges in which an income source doesn't pay (its unpaid leave plus unpaid periods).
    public func unpaidSpans(for income: IncomeSource) -> [DateSpan] {
        income.unpaidLeave + document.periods.filter { $0.unpaidIncomeIDs.contains(income.id) }.map(\.span)
    }
}

/// What happened to a planned occurrence before reconciliation.
public enum FlowState: String, Hashable, Sendable {
    /// Expected to happen.
    case planned
    /// You skipped this one.
    case skipped
    /// A period (e.g. Travel) pauses it.
    case paused
    /// A pay with nothing to pay (unpaid leave, no days worked).
    case unpaid
}

public enum FlowKind: String, Hashable, Sendable {
    case item, pay, taxSetAside, gstSetAside
}

/// One planned movement of money on a date.
public struct PlannedFlow: Hashable, Sendable, Identifiable {
    public var key: OccurrenceKey
    public var kind: FlowKind
    public var name: String
    /// When it happens (after business-day adjustment or a move).
    public var date: LocalDate
    /// Signed: money in is positive, money out negative. Zero when skipped, paused or unpaid.
    public var amount: Money
    /// What was planned before any skip or pause (signed).
    public var plannedAmount: Money
    public var accountID: UUID?
    public var state: FlowState
    public var isOverridden: Bool
    public var periodID: UUID?
    /// Set when bank data is available.
    public var reconciliation: FlowReconciliation?

    public var id: OccurrenceKey { key }
    public var isInflow: Bool { plannedAmount.cents > 0 }
    public var status: OccurrenceStatus? { reconciliation?.status }
}
