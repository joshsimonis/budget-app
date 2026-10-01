import Foundation

/// Money going out (bills, spending) or coming in (other than pay from an `IncomeSource`).
public enum Flow: String, Codable, Sendable, CaseIterable {
    case outflow, inflow

    /// +1 for money in, −1 for money out.
    public var sign: Int64 { self == .inflow ? 1 : -1 }
}

/// A stretch of time over which an item repeats with one amount. "Change from this date
/// onward" ends one segment and starts another with the same recurrence anchor, so the
/// phase (e.g. which Thursday a fortnightly bill lands on) never shifts.
public struct ScheduleSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var start: LocalDate
    /// Last day covered (inclusive); nil = no end.
    public var end: LocalDate?
    public var recurrence: Recurrence
    /// Always positive; the item's `flow` gives the direction.
    public var amount: Money

    public init(id: UUID = UUID(), start: LocalDate, end: LocalDate? = nil, recurrence: Recurrence, amount: Money) {
        self.id = id
        self.start = start
        self.end = end
        self.recurrence = recurrence
        self.amount = amount
    }

    /// A one-off on `date`.
    public static func once(_ date: LocalDate, amount: Money) -> ScheduleSegment {
        ScheduleSegment(start: date, end: date, recurrence: .once(date), amount: amount)
    }

    public func covers(_ date: LocalDate) -> Bool {
        date >= start && (end.map { date <= $0 } ?? true)
    }

    /// The part of `span` this segment covers.
    public func clipped(to span: DateSpan) -> DateSpan? {
        DateSpan.make(max(start, span.start), min(end ?? span.end, span.end))
    }

    /// Unadjusted occurrence dates of this segment inside `span`.
    public func originalDates(in span: DateSpan) -> [LocalDate] {
        guard let clipped = clipped(to: span) else { return [] }
        return recurrence.originalDates(in: clipped)
    }
}

/// A change to one occurrence, keyed by the date it would originally have happened.
public struct OccurrenceOverride: Hashable, Codable, Sendable {
    public var originalDate: LocalDate
    public var skip: Bool
    /// Replaces the planned amount (positive).
    public var amount: Money?
    /// Moves this occurrence to another date.
    public var movedTo: LocalDate?
    public var note: String?

    public init(originalDate: LocalDate, skip: Bool = false, amount: Money? = nil, movedTo: LocalDate? = nil, note: String? = nil) {
        self.originalDate = originalDate
        self.skip = skip
        self.amount = amount
        self.movedTo = movedTo
        self.note = note
    }

    public var isEmpty: Bool {
        !skip && amount == nil && movedTo == nil && (note?.isEmpty ?? true)
    }
}

/// A row in the budget: a bill, subscription, envelope, transfer or one-off.
public struct BudgetItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var flow: Flow
    public var accountID: UUID?
    /// Set for flexible spending (e.g. "Food $350/wk") tracked against Up categories/tags.
    public var envelope: EnvelopeRule?
    /// Non-overlapping, sorted by start.
    public var segments: [ScheduleSegment]
    public var overrides: [OccurrenceOverride]
    public var match: MatchRule?
    /// Set for lines that belong to a Period (e.g. "Travel $400/wk"); they only occur inside it.
    public var periodID: UUID?
    public var sortIndex: Int
    public var archived: Bool
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        flow: Flow = .outflow,
        accountID: UUID? = nil,
        envelope: EnvelopeRule? = nil,
        segments: [ScheduleSegment],
        overrides: [OccurrenceOverride] = [],
        match: MatchRule? = nil,
        periodID: UUID? = nil,
        sortIndex: Int = 0,
        archived: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.flow = flow
        self.accountID = accountID
        self.envelope = envelope
        self.segments = segments.sorted { $0.start < $1.start }
        self.overrides = overrides
        self.match = match
        self.periodID = periodID
        self.sortIndex = sortIndex
        self.archived = archived
        self.notes = notes
    }

    public var isEnvelope: Bool { envelope != nil }

    public var isOneOff: Bool {
        segments.count == 1 && segments[0].recurrence.rule.unit == .once
    }

    /// The segment whose range covers `date`.
    public func segment(covering date: LocalDate) -> ScheduleSegment? {
        segments.last { $0.covers(date) }
    }

    public func override(for originalDate: LocalDate) -> OccurrenceOverride? {
        overrides.first { $0.originalDate == originalDate }
    }

    /// Whether `date` is a scheduled (unadjusted) occurrence of this item.
    public func isOccurrence(_ date: LocalDate) -> Bool {
        guard let segment = segment(covering: date) else { return false }
        return segment.recurrence.isOccurrence(date)
    }

    /// The amount planned on or after `date` (the segment covering it, else the next one).
    public func amount(on date: LocalDate) -> Money? {
        segment(covering: date)?.amount ?? segments.first { $0.start > date }?.amount
    }
}
