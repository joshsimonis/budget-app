import Foundation

/// What an edit had to clean up as a side effect.
public struct EditReport: Hashable, Sendable {
    /// Overrides whose occurrence no longer exists after the edit.
    public var removedOverrides: [OccurrenceOverride] = []

    public init(removedOverrides: [OccurrenceOverride] = []) {
        self.removedOverrides = removedOverrides
    }

    public var isEmpty: Bool { removedOverrides.isEmpty }
}

/// Edits on budget items that keep their schedules consistent.
public enum ItemEdits {
    /// Changes the amount (and/or recurrence) from `date` onward. The schedule's anchor is
    /// kept unless you pass a new recurrence, so a fortnightly bill stays on the same weeks.
    /// With `replaceLater`, any later changes are dropped and this one applies forever.
    @discardableResult
    public static func changeFrom(
        _ date: LocalDate,
        in item: inout BudgetItem,
        amount: Money? = nil,
        recurrence: Recurrence? = nil,
        replaceLater: Bool = false
    ) -> EditReport {
        var segments = item.segments.sorted { $0.start < $1.start }
        if let index = segments.lastIndex(where: { $0.covers(date) }) {
            var old = segments[index]
            if old.start == date {
                if let amount { old.amount = amount }
                if let recurrence { old.recurrence = recurrence }
                if replaceLater {
                    old.end = nil
                    segments.removeSubrange((index + 1)...)
                }
                segments[index] = old
            } else {
                var new = old
                new.id = UUID()
                new.start = date
                if let amount { new.amount = amount }
                if let recurrence { new.recurrence = recurrence }
                old.end = date.adding(days: -1)
                segments[index] = old
                if replaceLater {
                    new.end = nil
                    segments.removeSubrange((index + 1)...)
                }
                segments.insert(new, at: index + 1)
            }
        } else if let template = segments.last(where: { $0.start <= date }) ?? segments.first {
            var new = ScheduleSegment(
                start: date,
                end: nil,
                recurrence: recurrence ?? template.recurrence,
                amount: amount ?? template.amount
            )
            if replaceLater {
                segments.removeAll { $0.start > date }
            } else if let next = segments.first(where: { $0.start > date }) {
                new.end = next.start.adding(days: -1)
            }
            segments.append(new)
            segments.sort { $0.start < $1.start }
        } else {
            return EditReport()
        }
        item.segments = segments
        normalize(&item)
        return EditReport(removedOverrides: removeOrphans(in: &item))
    }

    /// Stops an item from `date` (inclusive): nothing happens on or after it.
    @discardableResult
    public static func stop(_ item: inout BudgetItem, from date: LocalDate) -> EditReport {
        var segments: [ScheduleSegment] = []
        for var segment in item.segments.sorted(by: { $0.start < $1.start }) where segment.start < date {
            if segment.end.map({ $0 >= date }) ?? true {
                segment.end = date.adding(days: -1)
            }
            segments.append(segment)
        }
        item.segments = segments
        return EditReport(removedOverrides: removeOrphans(in: &item))
    }

    /// Adds or replaces the override for one occurrence (an empty override removes it).
    public static func setOverride(_ override: OccurrenceOverride, in item: inout BudgetItem) {
        item.overrides.removeAll { $0.originalDate == override.originalDate }
        if !override.isEmpty {
            item.overrides.append(override)
            item.overrides.sort { $0.originalDate < $1.originalDate }
        }
    }

    public static func removeOverride(originalDate: LocalDate, in item: inout BudgetItem) {
        item.overrides.removeAll { $0.originalDate == originalDate }
    }

    /// Overrides that no longer line up with a scheduled occurrence.
    public static func orphanedOverrides(in item: BudgetItem) -> [OccurrenceOverride] {
        item.overrides.filter { !item.isOccurrence($0.originalDate) }
    }

    @discardableResult
    public static func removeOrphans(in item: inout BudgetItem) -> [OccurrenceOverride] {
        let orphans = orphanedOverrides(in: item)
        if !orphans.isEmpty {
            let dates = Set(orphans.map(\.originalDate))
            item.overrides.removeAll { dates.contains($0.originalDate) }
        }
        return orphans
    }

    /// Merges back-to-back segments that are identical apart from their dates.
    public static func normalize(_ item: inout BudgetItem) {
        var merged: [ScheduleSegment] = []
        for segment in item.segments.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last,
               let lastEnd = last.end,
               lastEnd.adding(days: 1) == segment.start,
               last.recurrence == segment.recurrence,
               last.amount == segment.amount {
                last.end = segment.end
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        item.segments = merged
    }
}

/// Edits on income sources.
public enum IncomeEdits {
    /// Adds a rate from a date (a pay rise), replacing any rate that starts the same day.
    public static func setRate(_ rate: RateSegment, in income: inout IncomeSource) {
        income.rates.removeAll { $0.from == rate.from || $0.id == rate.id }
        income.rates.append(rate)
        income.rates.sort { $0.from < $1.from }
    }

    public static func removeRate(id: UUID, in income: inout IncomeSource) {
        guard income.rates.count > 1 else { return }
        income.rates.removeAll { $0.id == id }
    }

    /// Sets the days worked for one pay; nil goes back to the default (work days in the period).
    public static func setDaysWorked(_ hundredths: Int?, payDate: LocalDate, in income: inout IncomeSource) {
        income.daysWorked.removeAll { $0.payDate == payDate }
        if let hundredths {
            income.daysWorked.append(DaysWorked(payDate: payDate, hundredths: max(0, hundredths)))
            income.daysWorked.sort { $0.payDate < $1.payDate }
        }
    }

    public static func setOverride(_ override: OccurrenceOverride, in income: inout IncomeSource) {
        income.overrides.removeAll { $0.originalDate == override.originalDate }
        if !override.isEmpty {
            income.overrides.append(override)
            income.overrides.sort { $0.originalDate < $1.originalDate }
        }
    }

    /// Overrides and day counts whose pay date is no longer a pay date.
    @discardableResult
    public static func removeOrphans(in income: inout IncomeSource) -> [OccurrenceOverride] {
        let schedule = income.paySchedule
        let orphans = income.overrides.filter { !schedule.isOccurrence($0.originalDate) }
        income.overrides.removeAll { !schedule.isOccurrence($0.originalDate) }
        income.daysWorked.removeAll { !schedule.isOccurrence($0.payDate) }
        return orphans
    }
}
