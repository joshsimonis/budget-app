import Foundation

/// A bank account the budget knows about, e.g. "Essentials" or "Spending".
/// Items are tied to an account so they match the right transactions; the running
/// total adds up every account with `includedInTotal`.
public struct Account: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// The linked Up account id, once Up is connected.
    public var upAccountID: String?
    public var includedInTotal: Bool
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, upAccountID: String? = nil, includedInTotal: Bool = true, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.upAccountID = upAccountID
        self.includedInTotal = includedInTotal
        self.sortIndex = sortIndex
    }
}

/// How a planned item is recognised among bank transactions.
public struct MatchRule: Hashable, Codable, Sendable {
    /// Case-insensitive text found in the transaction's description or raw text. Any one is enough.
    public var patterns: [String]
    /// For payments into a saver that isn't counted in the total (e.g. a tax saver): the Up
    /// account on the other side of the transfer.
    public var counterpartyUpAccountID: String?
    /// Overrides the default amount tolerance, in basis points of the planned amount.
    public var toleranceBasisPoints: Int?

    public init(patterns: [String] = [], counterpartyUpAccountID: String? = nil, toleranceBasisPoints: Int? = nil) {
        self.patterns = patterns
        self.counterpartyUpAccountID = counterpartyUpAccountID
        self.toleranceBasisPoints = toleranceBasisPoints
    }

    public var isEmpty: Bool {
        patterns.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } && counterpartyUpAccountID == nil
    }
}

/// Which bank transactions count against a flexible-spending envelope.
public struct EnvelopeRule: Hashable, Codable, Sendable {
    /// Up category ids. A parent category includes its children.
    public var categoryIDs: [String]
    /// Up tag labels.
    public var tagIDs: [String]

    public init(categoryIDs: [String] = [], tagIDs: [String] = []) {
        self.categoryIDs = categoryIDs
        self.tagIDs = tagIDs
    }
}
