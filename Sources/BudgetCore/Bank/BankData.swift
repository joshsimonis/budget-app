import Foundation

/// A bank account as reported by Up.
public struct BankAccount: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// "TRANSACTIONAL", "SAVER", "HOME_LOAN" (or anything new Up adds).
    public var accountType: String
    /// "INDIVIDUAL" or "JOINT".
    public var ownershipType: String
    /// Available balance (net of held transactions).
    public var balance: Money
    public var createdAt: Date?

    public init(id: String, name: String, accountType: String, ownershipType: String, balance: Money, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.accountType = accountType
        self.ownershipType = ownershipType
        self.balance = balance
        self.createdAt = createdAt
    }

    public var isSaver: Bool { accountType == "SAVER" }
    public var isHomeLoan: Bool { accountType == "HOME_LOAN" }
    public var isJoint: Bool { ownershipType == "JOINT" }
}

public enum TransactionStatus: String, Codable, Sendable {
    case held = "HELD"
    case settled = "SETTLED"
}

/// A bank transaction. Amounts are signed: money out is negative.
public struct BankTransaction: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var accountID: String
    public var status: TransactionStatus
    public var createdAt: Date
    public var settledAt: Date?
    public var description: String
    public var rawText: String?
    public var message: String?
    public var amount: Money
    /// Rounded up into a saver (negative), if any.
    public var roundUp: Money?
    /// e.g. "IDR -1053698.77" for purchases overseas.
    public var foreignAmount: String?
    public var categoryID: String?
    public var parentCategoryID: String?
    public var tagIDs: [String]
    /// Set when money moved between your own accounts.
    public var transferAccountID: String?
    public var transactionType: String?
    public var deepLinkURL: String?

    public init(
        id: String, accountID: String, status: TransactionStatus, createdAt: Date, settledAt: Date? = nil,
        description: String, rawText: String? = nil, message: String? = nil, amount: Money, roundUp: Money? = nil,
        foreignAmount: String? = nil, categoryID: String? = nil, parentCategoryID: String? = nil, tagIDs: [String] = [],
        transferAccountID: String? = nil, transactionType: String? = nil, deepLinkURL: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.status = status
        self.createdAt = createdAt
        self.settledAt = settledAt
        self.description = description
        self.rawText = rawText
        self.message = message
        self.amount = amount
        self.roundUp = roundUp
        self.foreignAmount = foreignAmount
        self.categoryID = categoryID
        self.parentCategoryID = parentCategoryID
        self.tagIDs = tagIDs
        self.transferAccountID = transferAccountID
        self.transactionType = transactionType
        self.deepLinkURL = deepLinkURL
    }

    public var isTransfer: Bool { transferAccountID != nil }

    /// The change to the account balance, including any round-up.
    public var balanceDelta: Money { amount + (roundUp ?? .zero) }

    /// Lower-cased description with runs of whitespace collapsed (for matching).
    public var normalizedDescription: String { TextMatch.normalize(description) }
}

public struct BankCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?

    public init(id: String, name: String, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

/// Everything fetched from the bank, cached on disk next to the budget.
public struct BankCache: Codable, Hashable, Sendable {
    public var accounts: [BankAccount]
    /// Sorted oldest first.
    public var transactions: [BankTransaction]
    public var categories: [BankCategory]
    public var tags: [String]
    /// Transactions are complete from this instant on.
    public var coverageStart: Date?
    public var lastSync: Date?
    public var categoriesFetchedAt: Date?
    /// How the last sync's balance change compared with the transactions it brought in.
    public var balanceCheck: BalanceCheck?

    public init(accounts: [BankAccount] = [], transactions: [BankTransaction] = [], categories: [BankCategory] = [],
                tags: [String] = [], coverageStart: Date? = nil, lastSync: Date? = nil, categoriesFetchedAt: Date? = nil,
                balanceCheck: BalanceCheck? = nil) {
        self.accounts = accounts
        self.transactions = transactions
        self.categories = categories
        self.tags = tags
        self.coverageStart = coverageStart
        self.lastSync = lastSync
        self.categoriesFetchedAt = categoriesFetchedAt
        self.balanceCheck = balanceCheck
    }

    public static let empty = BankCache()

    public func account(_ id: String) -> BankAccount? { accounts.first { $0.id == id } }
    public func category(_ id: String?) -> BankCategory? { id.flatMap { id in categories.first { $0.id == id } } }

    public func transaction(_ id: String) -> BankTransaction? { transactions.first { $0.id == id } }

    /// Category ids including all children of any parent ids given.
    public func expandCategories(_ ids: [String]) -> Set<String> {
        var result = Set(ids)
        for category in categories where category.parentID.map(result.contains) == true {
            result.insert(category.id)
        }
        return result
    }

    public static func encode(_ cache: BankCache) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(cache)
    }

    public static func decode(_ data: Data) throws -> BankCache {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BankCache.self, from: data)
    }
}

/// Text helpers for matching descriptions.
public enum TextMatch {
    public static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True if any non-empty pattern appears in the description or raw text.
    public static func matches(_ patterns: [String], _ transaction: BankTransaction) -> Bool {
        let haystacks = [normalize(transaction.description), normalize(transaction.rawText ?? "")]
        return patterns.contains { pattern in
            let needle = normalize(pattern)
            return !needle.isEmpty && haystacks.contains { $0.contains(needle) }
        }
    }
}

public struct MergeReport: Hashable, Sendable {
    public var inserted: Int = 0
    public var updated: Int = 0
    /// Transactions that disappeared from the bank (deleted, or replaced by a new id).
    public var removed: [BankTransaction] = []

    public init(inserted: Int = 0, updated: Int = 0, removed: [BankTransaction] = []) {
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
    }
}

public enum TransactionMerge {
    /// Upserts `fetched` by id. When the fetch covered everything from `windowStart` on
    /// (`complete`), cached transactions in that window that weren't returned are removed.
    @discardableResult
    public static func apply(fetched: [BankTransaction], windowStart: Date, complete: Bool, to cache: inout BankCache) -> MergeReport {
        var report = MergeReport()
        var index = Dictionary(uniqueKeysWithValues: cache.transactions.enumerated().map { ($1.id, $0) })
        for transaction in fetched {
            if let existing = index[transaction.id] {
                if cache.transactions[existing] != transaction {
                    cache.transactions[existing] = transaction
                    report.updated += 1
                }
            } else {
                index[transaction.id] = cache.transactions.count
                cache.transactions.append(transaction)
                report.inserted += 1
            }
        }
        if complete {
            let seen = Set(fetched.map(\.id))
            report.removed = cache.transactions.filter { $0.createdAt >= windowStart && !seen.contains($0.id) }
            if !report.removed.isEmpty {
                let removedIDs = Set(report.removed.map(\.id))
                cache.transactions.removeAll { removedIDs.contains($0.id) }
            }
        }
        cache.transactions.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return report
    }
}

public enum LinkRepair {
    /// Points manual links at a replacement when the bank swapped a transaction's id
    /// (same account and description, amount within 10%, within 3 days). Links that can't
    /// be repaired are dropped. Returns a note for each one dropped.
    @discardableResult
    public static func repair(_ state: inout ReconciliationState, removed: [BankTransaction], cache: BankCache) -> [String] {
        guard !removed.isEmpty else { return [] }
        let removedByID = Dictionary(uniqueKeysWithValues: removed.map { ($0.id, $0) })
        var linked = Set(state.manualLinks.flatMap(\.transactionIDs))
        var notes: [String] = []
        for linkIndex in state.manualLinks.indices {
            var ids: [String] = []
            for id in state.manualLinks[linkIndex].transactionIDs {
                guard let old = removedByID[id] else {
                    ids.append(id)
                    continue
                }
                let replacement = cache.transactions.first { candidate in
                    !linked.contains(candidate.id)
                        && candidate.accountID == old.accountID
                        && candidate.normalizedDescription == old.normalizedDescription
                        && abs(candidate.createdAt.timeIntervalSince(old.createdAt)) <= 3 * 86_400
                        && candidate.amount.magnitude.cents * 10 >= old.amount.magnitude.cents * 9
                        && candidate.amount.magnitude.cents * 10 <= old.amount.magnitude.cents * 11
                }
                if let replacement {
                    ids.append(replacement.id)
                    linked.insert(replacement.id)
                } else {
                    notes.append("A transaction you linked (\(old.description), \(MoneyFormat.string(old.amount.magnitude))) is no longer at the bank, so its link was removed.")
                }
            }
            state.manualLinks[linkIndex].transactionIDs = ids
        }
        state.manualLinks.removeAll { $0.transactionIDs.isEmpty }
        let removedIDs = Set(removed.map(\.id))
        state.ignoredTransactionIDs.removeAll { removedIDs.contains($0) }
        return notes
    }
}

/// Compares the change in total balance between two syncs with the transactions created in
/// between. A steady gap points at something the app doesn't see (for example round-ups).
public struct BalanceCheck: Codable, Hashable, Sendable {
    public var from: Date
    public var to: Date
    public var balanceChange: Money
    public var transactionTotal: Money
    public var transactionCount: Int

    public init(from: Date, to: Date, balanceChange: Money, transactionTotal: Money, transactionCount: Int) {
        self.from = from
        self.to = to
        self.balanceChange = balanceChange
        self.transactionTotal = transactionTotal
        self.transactionCount = transactionCount
    }

    public var difference: Money { balanceChange - transactionTotal }

    public static func make(previous: BankCache, current: BankCache, now: Date) -> BalanceCheck? {
        guard let from = previous.lastSync, !previous.accounts.isEmpty else { return nil }
        let ids = Set(previous.accounts.map(\.id)).intersection(current.accounts.map(\.id))
        let before = previous.accounts.filter { ids.contains($0.id) }.reduce(Money.zero) { $0 + $1.balance }
        let after = current.accounts.filter { ids.contains($0.id) }.reduce(Money.zero) { $0 + $1.balance }
        let fresh = current.transactions.filter { ids.contains($0.accountID) && $0.createdAt > from && previous.transaction($0.id) == nil }
        // Held transactions that changed amount when they settled also move the balance.
        let changed = current.transactions.compactMap { transaction -> Money? in
            guard ids.contains(transaction.accountID), let old = previous.transaction(transaction.id), old.balanceDelta != transaction.balanceDelta else { return nil }
            return transaction.balanceDelta - old.balanceDelta
        }
        let total = fresh.reduce(Money.zero) { $0 + $1.balanceDelta } + changed.reduce(Money.zero, +)
        return BalanceCheck(from: from, to: now, balanceChange: after - before, transactionTotal: total, transactionCount: fresh.count)
    }
}
