import Foundation

public enum PeriodColor: String, Codable, Sendable, CaseIterable {
    case green, blue, orange, purple, pink, teal, yellow, gray
}

/// A named stretch of time such as "Travel": it pauses chosen items, can mark income as
/// unpaid, and owns its own lines (items with `periodID` set to this period).
public struct Period: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var color: PeriodColor
    public var span: DateSpan
    /// Items that don't happen while this period is on (e.g. groceries, public transport).
    public var pausedItemIDs: [UUID]
    /// Income sources that don't pay for work days inside this period (unpaid leave).
    public var unpaidIncomeIDs: [UUID]
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        color: PeriodColor = .green,
        span: DateSpan,
        pausedItemIDs: [UUID] = [],
        unpaidIncomeIDs: [UUID] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.span = span
        self.pausedItemIDs = pausedItemIDs
        self.unpaidIncomeIDs = unpaidIncomeIDs
        self.notes = notes
    }
}

/// A bank balance you know, applied at the start of `date` (like the sheet's "Cash - Bank" row).
/// Used to anchor the running total when Up isn't connected.
public struct BalanceCheckpoint: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var date: LocalDate
    public var amount: Money
    public var note: String

    public init(id: UUID = UUID(), date: LocalDate, amount: Money, note: String = "") {
        self.id = id
        self.date = date
        self.amount = amount
        self.note = note
    }
}

/// Identifies one planned occurrence: an item or income source, the date it was originally
/// scheduled, and which part (the main amount or an ABN set-aside).
public struct OccurrenceKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public enum Part: String, Codable, Sendable, CaseIterable {
        case main, taxSetAside, gstSetAside

        var sortOrder: Int {
            switch self {
            case .main: 0
            case .taxSetAside: 1
            case .gstSetAside: 2
            }
        }
    }

    public var sourceID: UUID
    public var originalDate: LocalDate
    public var part: Part

    public init(sourceID: UUID, originalDate: LocalDate, part: Part = .main) {
        self.sourceID = sourceID
        self.originalDate = originalDate
        self.part = part
    }

    public static func < (lhs: OccurrenceKey, rhs: OccurrenceKey) -> Bool {
        if lhs.originalDate != rhs.originalDate { return lhs.originalDate < rhs.originalDate }
        if lhs.sourceID != rhs.sourceID { return lhs.sourceID.uuidString < rhs.sourceID.uuidString }
        return lhs.part.sortOrder < rhs.part.sortOrder
    }

    public var description: String { "\(sourceID.uuidString.prefix(8))@\(originalDate)/\(part.rawValue)" }
}

/// Reconciliation decisions you've made by hand. Everything else is recomputed.
public struct ManualLink: Hashable, Codable, Sendable {
    public var occurrence: OccurrenceKey
    public var transactionIDs: [String]

    public init(occurrence: OccurrenceKey, transactionIDs: [String]) {
        self.occurrence = occurrence
        self.transactionIDs = transactionIDs
    }
}

public struct ReconciliationState: Hashable, Codable, Sendable {
    public var manualLinks: [ManualLink]
    /// Transactions you've said not to match to anything (e.g. a one-off refund).
    public var ignoredTransactionIDs: [String]
    /// Occurrences you've marked as paid without a matching transaction.
    public var markedPaid: [OccurrenceKey]
    /// Suggestions you've dismissed (by merchant key).
    public var dismissedSuggestionKeys: [String]

    public init(manualLinks: [ManualLink] = [], ignoredTransactionIDs: [String] = [], markedPaid: [OccurrenceKey] = [], dismissedSuggestionKeys: [String] = []) {
        self.manualLinks = manualLinks
        self.ignoredTransactionIDs = ignoredTransactionIDs
        self.markedPaid = markedPaid
        self.dismissedSuggestionKeys = dismissedSuggestionKeys
    }
}
