import Foundation

/// Where a planned occurrence stands against the bank.
public enum OccurrenceStatus: String, Hashable, Sendable {
    /// Still to come.
    case upcoming
    /// Matched to a bank transaction.
    case matched
    /// You marked it as paid.
    case markedPaid
    /// Due, or overdue within the grace period, with no matching transaction yet.
    case pending
    /// Overdue past the grace period with no matching transaction.
    case missed
    /// In the past but not set up for matching (or before bank history): assumed to have happened.
    case assumed
}

public struct FlowReconciliation: Hashable, Sendable {
    public var status: OccurrenceStatus
    public var transactionIDs: [String]
    /// Signed total of the matched transactions.
    public var actualAmount: Money?
    /// Date of the earliest matched transaction.
    public var actualDate: LocalDate?
    public var isManual: Bool

    public init(status: OccurrenceStatus, transactionIDs: [String] = [], actualAmount: Money? = nil, actualDate: LocalDate? = nil, isManual: Bool = false) {
        self.status = status
        self.transactionIDs = transactionIDs
        self.actualAmount = actualAmount
        self.actualDate = actualDate
        self.isManual = isManual
    }
}

/// What was actually spent in one envelope period.
public struct EnvelopeSpend: Hashable, Sendable {
    /// Net spending (refunds reduce it); can be negative after a big refund.
    public var spent: Money
    public var transactionIDs: [String]
    /// Net spending per day (positive = spending).
    public var daily: [DayAmount]

    public init(spent: Money = .zero, transactionIDs: [String] = [], daily: [DayAmount] = []) {
        self.spent = spent
        self.transactionIDs = transactionIDs
        self.daily = daily
    }
}

/// A bank transaction with the local date it happened on.
public struct DatedTransaction: Hashable, Sendable, Identifiable {
    public var transaction: BankTransaction
    public var date: LocalDate

    public init(transaction: BankTransaction, date: LocalDate) {
        self.transaction = transaction
        self.date = date
    }

    public var id: String { transaction.id }
}

public struct ReconciliationResult: Sendable {
    public var flows: [OccurrenceKey: FlowReconciliation] = [:]
    public var envelopes: [OccurrenceKey: EnvelopeSpend] = [:]
    /// Transactions that move your counted balance but aren't part of the plan.
    public var unplanned: [DatedTransaction] = []
    /// Which occurrence (item, pay or envelope period) each transaction went to.
    public var assignments: [String: OccurrenceKey] = [:]

    public init() {}
}

public struct ReconcileOptions: Sendable {
    public var today: LocalDate
    public var graceDays: Int
    /// Bank history is complete from this date.
    public var coverageStart: LocalDate?
    /// Last day already reflected in the bank balance (normally today).
    public var anchorDate: LocalDate

    public init(today: LocalDate, graceDays: Int, coverageStart: LocalDate?, anchorDate: LocalDate) {
        self.today = today
        self.graceDays = graceDays
        self.coverageStart = coverageStart
        self.anchorDate = anchorDate
    }
}

/// Matches planned occurrences to bank transactions. A pure, deterministic recompute:
/// only manual links, ignored transactions and "marked paid" are stored.
public enum Reconciler {
    public static func reconcile(
        flows: [PlannedFlow],
        envelopes: [EnvelopePeriod],
        transactions: [DatedTransaction],
        document: BudgetDocument,
        bank: BankCache,
        options: ReconcileOptions
    ) -> ReconciliationResult {
        var result = ReconciliationResult()
        let state = document.reconciliation
        let byID = Dictionary(transactions.map { ($0.transaction.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ignored = Set(state.ignoredTransactionIDs)
        var used = Set<String>()
        let planned = flows.filter { $0.state == .planned }
        let plannedKeys = Set(planned.map(\.key))

        // 1. Manual links win.
        for link in state.manualLinks where plannedKeys.contains(link.occurrence) {
            let ids = link.transactionIDs.filter { byID[$0] != nil && !used.contains($0) }
            guard !ids.isEmpty else { continue }
            used.formUnion(ids)
            let amount = ids.reduce(Money.zero) { $0 + byID[$1]!.transaction.amount }
            let date = ids.compactMap { byID[$0]?.date }.min()
            result.flows[link.occurrence] = FlowReconciliation(status: .matched, transactionIDs: ids, actualAmount: amount, actualDate: date, isManual: true)
            for id in ids { result.assignments[id] = link.occurrence }
        }

        // 2. Marked as paid.
        for key in state.markedPaid where plannedKeys.contains(key) && result.flows[key] == nil {
            result.flows[key] = FlowReconciliation(status: .markedPaid, isManual: true)
        }

        // 3. Scored candidates, assigned best-first, one to one.
        struct Candidate {
            var flow: PlannedFlow
            var transaction: DatedTransaction
            var score: Double
            var distance: Int
        }
        let upAccountByBudgetAccount = Dictionary(document.accounts.compactMap { account in account.upAccountID.map { (account.id, $0) } },
                                                  uniquingKeysWith: { first, _ in first })
        var candidates: [Candidate] = []
        let sortedTransactions = transactions.sorted { ($0.date, $0.transaction.createdAt, $0.transaction.id) < ($1.date, $1.transaction.createdAt, $1.transaction.id) }
        for flow in planned where result.flows[flow.key] == nil {
            guard let rule = matchRule(for: flow, in: document), !rule.isEmpty else { continue }
            if let coverage = options.coverageStart, flow.date < coverage { continue }
            let (before, after) = window(for: flow, in: document)
            let low = flow.date.adding(days: -before)
            let high = flow.date.adding(days: after)
            let plannedCents = flow.plannedAmount.magnitude.cents
            guard plannedCents > 0 else { continue }
            for dated in sortedTransactions where dated.date >= low && dated.date <= high {
                let txn = dated.transaction
                guard !used.contains(txn.id), !ignored.contains(txn.id), !txn.amount.isZero,
                      txn.amount.isPositive == flow.plannedAmount.isPositive else { continue }
                let counterpartyMatch = rule.counterpartyUpAccountID.map { $0 == txn.transferAccountID } ?? false
                if txn.isTransfer && !counterpartyMatch { continue }
                guard counterpartyMatch || TextMatch.matches(rule.patterns, txn) else { continue }
                let actualCents = txn.amount.magnitude.cents
                let difference = abs(actualCents - plannedCents)
                if let tolerance = rule.toleranceBasisPoints {
                    guard difference * 10_000 <= plannedCents * Int64(tolerance) + 100 * 10_000 else { continue }
                } else {
                    guard actualCents * 2 >= plannedCents, actualCents <= plannedCents * 2 else { continue }
                }
                let amountCloseness = 1 - min(1, Double(difference) / Double(plannedCents))
                let distance = abs(dated.date - flow.date)
                let dateCloseness = 1 - Double(distance) / Double(max(before, after) + 1)
                var score = 0.5 * amountCloseness + 0.3 * dateCloseness + 0.2
                if let expected = flow.accountID.flatMap({ upAccountByBudgetAccount[$0] }), expected != txn.accountID {
                    score -= 0.1
                }
                candidates.append(Candidate(flow: flow, transaction: dated, score: score, distance: distance))
            }
        }
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.distance != b.distance { return a.distance < b.distance }
            if a.flow.date != b.flow.date { return a.flow.date < b.flow.date }
            if a.flow.key != b.flow.key { return a.flow.key < b.flow.key }
            if a.transaction.transaction.createdAt != b.transaction.transaction.createdAt {
                return a.transaction.transaction.createdAt < b.transaction.transaction.createdAt
            }
            return a.transaction.transaction.id < b.transaction.transaction.id
        }
        for candidate in candidates {
            let key = candidate.flow.key
            let id = candidate.transaction.transaction.id
            guard result.flows[key] == nil, !used.contains(id) else { continue }
            used.insert(id)
            result.assignments[id] = key
            result.flows[key] = FlowReconciliation(
                status: .matched,
                transactionIDs: [id],
                actualAmount: candidate.transaction.transaction.amount,
                actualDate: candidate.transaction.date
            )
        }

        // 4. Status for everything still unmatched.
        for flow in planned where result.flows[flow.key] == nil {
            let rule = matchRule(for: flow, in: document)
            let beforeHistory = options.coverageStart.map { flow.date < $0 } ?? false
            if rule == nil || rule?.isEmpty == true || beforeHistory {
                if flow.date < options.anchorDate {
                    result.flows[flow.key] = FlowReconciliation(status: .assumed)
                }
                continue
            }
            if flow.date > options.today {
                result.flows[flow.key] = FlowReconciliation(status: .upcoming)
            } else if options.today - flow.date <= options.graceDays {
                result.flows[flow.key] = FlowReconciliation(status: .pending)
            } else {
                result.flows[flow.key] = FlowReconciliation(status: .missed)
            }
        }

        // 5. Envelope spending: category or tag matches, in the first envelope (by order) that fits.
        let envelopeItems = document.items.filter { $0.isEnvelope && !$0.archived }.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
        let rules = envelopeItems.map { item -> (UUID, Set<String>, Set<String>) in
            (item.id, bank.expandCategories(item.envelope?.categoryIDs ?? []), Set(item.envelope?.tagIDs ?? []))
        }
        let periodsByItem = Dictionary(grouping: envelopes.filter { $0.state != .skipped }, by: \.itemID)
        for dated in sortedTransactions {
            let txn = dated.transaction
            guard !used.contains(txn.id), !ignored.contains(txn.id), !txn.isTransfer else { continue }
            for (itemID, categories, tags) in rules {
                let categoryMatch = [txn.categoryID, txn.parentCategoryID].contains { $0.map(categories.contains) ?? false }
                let tagMatch = txn.tagIDs.contains { tags.contains($0) }
                guard categoryMatch || tagMatch,
                      let period = periodsByItem[itemID]?.first(where: { $0.span.contains(dated.date) }) else { continue }
                used.insert(txn.id)
                result.assignments[txn.id] = period.key
                var spend = result.envelopes[period.key] ?? EnvelopeSpend()
                spend.spent -= txn.amount
                spend.transactionIDs.append(txn.id)
                if let index = spend.daily.firstIndex(where: { $0.date == dated.date }) {
                    spend.daily[index].amount -= txn.amount
                } else {
                    spend.daily.append(DayAmount(date: dated.date, amount: -txn.amount))
                }
                result.envelopes[period.key] = spend
                break
            }
        }

        // 6. Everything else is unplanned.
        result.unplanned = sortedTransactions.filter { !used.contains($0.transaction.id) }
        return result
    }

    static func matchRule(for flow: PlannedFlow, in document: BudgetDocument) -> MatchRule? {
        switch flow.kind {
        case .item: document.item(flow.key.sourceID)?.match
        case .pay: document.income(flow.key.sourceID)?.match
        case .taxSetAside, .gstSetAside: nil
        }
    }

    /// Days before and after the planned date that a matching transaction may fall.
    static func window(for flow: PlannedFlow, in document: BudgetDocument) -> (Int, Int) {
        if flow.kind == .pay { return (3, 4) }
        guard let rule = document.item(flow.key.sourceID)?.segment(covering: flow.key.originalDate)?.recurrence.rule else { return (3, 7) }
        switch rule.unit {
        case .once: return (3, 7)
        case .day: return (0, 1)
        case .week: return rule.interval == 1 ? (2, 3) : (rule.interval == 2 ? (3, 4) : (4, 6))
        case .month: return (4, 6)
        case .year: return (7, 14)
        }
    }
}
