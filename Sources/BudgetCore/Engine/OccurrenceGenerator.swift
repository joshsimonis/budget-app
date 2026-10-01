import Foundation

/// Turns budget items into planned flows (point-in-time items) and envelope periods.
public enum OccurrenceGenerator {
    /// Planned flows for a non-envelope item inside the context's horizon.
    public static func flows(for item: BudgetItem, context: PlanContext) -> [PlannedFlow] {
        guard !item.archived, !item.isEnvelope else { return [] }
        var span = context.horizon.expanded(by: 7)
        if let periodID = item.periodID {
            guard let period = context.document.period(periodID), let clipped = span.intersection(period.span) else { return [] }
            span = clipped
        }

        // Original dates to consider: those near the horizon plus any moved into it from further away.
        var originals: [(LocalDate, ScheduleSegment)] = []
        var seen = Set<LocalDate>()
        for segment in item.segments {
            for date in segment.originalDates(in: span) where seen.insert(date).inserted {
                originals.append((date, segment))
            }
        }
        for override in item.overrides {
            guard let moved = override.movedTo, context.horizon.contains(moved), !seen.contains(override.originalDate),
                  let segment = item.segment(covering: override.originalDate),
                  segment.recurrence.isOccurrence(override.originalDate) else { continue }
            if let periodID = item.periodID, let period = context.document.period(periodID),
               !period.span.contains(override.originalDate) { continue }
            seen.insert(override.originalDate)
            originals.append((override.originalDate, segment))
        }

        var result: [PlannedFlow] = []
        for (original, segment) in originals {
            let override = item.override(for: original)
            let date = override?.movedTo ?? context.calendar.adjust(original, segment.recurrence.adjustment)
            guard context.horizon.contains(date) else { continue }
            let planned = Money(cents: (override?.amount ?? segment.amount).cents * item.flow.sign)
            var state = FlowState.planned
            if override?.skip == true {
                state = .skipped
            } else if context.isPaused(item.id, on: date) {
                state = .paused
            }
            result.append(PlannedFlow(
                key: OccurrenceKey(sourceID: item.id, originalDate: original),
                kind: .item,
                name: item.name,
                date: date,
                amount: state == .planned ? planned : .zero,
                plannedAmount: planned,
                accountID: item.accountID,
                state: state,
                isOverridden: override != nil,
                periodID: item.periodID,
                reconciliation: nil
            ))
        }
        return result.sorted { ($0.date, $0.key) < ($1.date, $1.key) }
    }
}

/// One budgeting period of an envelope (e.g. one week of "Food $300").
public struct EnvelopePeriod: Hashable, Sendable, Identifiable {
    public var key: OccurrenceKey
    public var itemID: UUID
    public var name: String
    public var accountID: UUID?
    /// The whole period, e.g. Monday–Sunday.
    public var span: DateSpan
    /// The budget for the days that aren't paused (positive).
    public var budget: Money
    /// The budget before pausing or skipping.
    public var fullBudget: Money
    public var state: FlowState
    public var isOverridden: Bool
    /// The budget spread over the active days (exact cents; earlier days get leftover cents).
    /// With bank data, only what's left of the budget from today on.
    public var allocations: [DayAmount]
    /// With bank data: what was actually spent so far, and on which days.
    public var spend: EnvelopeSpend?

    public var id: OccurrenceKey { key }

    /// Budget minus actual spending (never below zero).
    public var remaining: Money? {
        spend.map { max(.zero, budget - $0.spent) }
    }
}

public struct DayAmount: Hashable, Sendable {
    public var date: LocalDate
    public var amount: Money

    public init(date: LocalDate, amount: Money) {
        self.date = date
        self.amount = amount
    }
}

public enum EnvelopeAllocator {
    /// Envelope periods for an envelope item that overlap the horizon.
    public static func periods(for item: BudgetItem, context: PlanContext) -> [EnvelopePeriod] {
        guard !item.archived, item.isEnvelope else { return [] }
        var limit = context.horizon
        var periodSpan: DateSpan?
        if let periodID = item.periodID {
            guard let period = context.document.period(periodID), let clipped = limit.intersection(period.span) else { return [] }
            limit = clipped
            periodSpan = period.span
        }

        var result: [EnvelopePeriod] = []
        for segment in item.segments {
            let recurrence = segment.recurrence
            guard let active = segment.clipped(to: limit) else { continue }
            // Every envelope period that overlaps `active`: from the occurrence on or before its start.
            var starts: [LocalDate] = []
            if recurrence.rule.unit == .once {
                starts = active.contains(recurrence.anchor) ? [recurrence.anchor] : []
            } else {
                let first = recurrence.index(onOrBefore: active.start).map { recurrence.date(at: $0) } ?? recurrence.anchor
                var current = first
                while current <= active.end {
                    starts.append(current)
                    guard let next = recurrence.next(onOrAfter: current.adding(days: 1)) else { break }
                    current = next
                }
            }

            for start in starts {
                let fullEnd: LocalDate
                if recurrence.rule.unit == .once {
                    fullEnd = start
                } else {
                    fullEnd = (recurrence.next(onOrAfter: start.adding(days: 1)) ?? start.adding(days: 1)).adding(days: -1)
                }
                let fullSpan = DateSpan(start: start, end: fullEnd)
                // Days this segment (and the item's period, if any) actually covers.
                guard let covered = segment.clipped(to: fullSpan),
                      let coveredInLimit = (periodSpan.map { covered.intersection($0) } ?? covered) else { continue }

                let override = item.override(for: start)
                let periodBudget = override?.amount ?? segment.amount
                let coveredDays = Array(coveredInLimit.dates)
                let activeDays = coveredDays.filter { !context.isPaused(item.id, on: $0) }
                var state = FlowState.planned
                var budget = periodBudget.scaled(Int64(activeDays.count), Int64(fullSpan.dayCount))
                if override?.skip == true {
                    state = .skipped
                    budget = .zero
                } else if activeDays.isEmpty {
                    state = .paused
                    budget = .zero
                }
                let allocations = budget.isZero || activeDays.isEmpty ? [] : zip(activeDays, budget.split(activeDays.count)).map {
                    DayAmount(date: $0.0, amount: $0.1)
                }
                guard fullSpan.overlaps(context.horizon) else { continue }
                result.append(EnvelopePeriod(
                    key: OccurrenceKey(sourceID: item.id, originalDate: start),
                    itemID: item.id,
                    name: item.name,
                    accountID: item.accountID,
                    span: fullSpan,
                    budget: budget,
                    fullBudget: periodBudget,
                    state: state,
                    isOverridden: override != nil,
                    allocations: allocations.filter { context.horizon.contains($0.date) },
                    spend: nil
                ))
            }
        }
        return result.sorted { $0.span.start < $1.span.start }
    }
}
