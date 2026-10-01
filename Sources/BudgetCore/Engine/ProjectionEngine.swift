import Foundation

/// One day of the running total.
public struct DayLedger: Hashable, Sendable {
    public var date: LocalDate
    /// Money in (positive).
    public var inflow: Money
    /// Money out (positive).
    public var outflow: Money
    /// Balance at the start of the day; nil until something anchors it.
    public var opening: Money?
    public var closing: Money?
    /// A balance you entered for the start of this day (manual mode).
    public var checkpoint: Money?
    /// True for days whose figures come entirely from real bank data.
    public var isActual: Bool

    public var net: Money { inflow - outflow }
}

/// Everything the app shows, computed from the document (and bank data, when connected).
public struct Projection: Sendable {
    public enum Mode: String, Sendable {
        /// Anchored by balances you enter.
        case manual
        /// Anchored by your Up balance and checked against Up transactions.
        case bank
    }

    public var today: LocalDate
    public var horizon: DateSpan
    public var mode: Mode
    public var flows: [PlannedFlow]
    public var envelopes: [EnvelopePeriod]
    public var payEvents: [PayEvent]
    public var estimates: [AnnualTaxEstimate]
    /// One per day of the horizon.
    public var days: [DayLedger]
    public var warnings: [String]
    /// Bank mode: transactions that aren't part of the plan.
    public var unplanned: [DatedTransaction]
    /// Bank mode: which planned occurrence each transaction was matched or counted to.
    public var assignments: [String: OccurrenceKey] = [:]
    /// Bank mode: the counted Up balance and the day it was synced.
    public var bankBalance: Money?
    public var bankBalanceDate: LocalDate?

    public func dayIndex(_ date: LocalDate) -> Int? {
        guard horizon.contains(date) else { return nil }
        return date - horizon.start
    }

    public func ledger(on date: LocalDate) -> DayLedger? {
        dayIndex(date).map { days[$0] }
    }

    /// The lowest closing balance from today on.
    public var lowestUpcoming: DayLedger? {
        days.filter { $0.date >= today && $0.closing != nil }.min { $0.closing! < $1.closing! }
    }

    public func payEvent(_ key: OccurrenceKey) -> PayEvent? {
        payEvents.first { $0.sourceID == key.sourceID && $0.originalDate == key.originalDate }
    }

    public func flow(_ key: OccurrenceKey) -> PlannedFlow? {
        flows.first { $0.key == key }
    }

    public func envelope(_ key: OccurrenceKey) -> EnvelopePeriod? {
        envelopes.first { $0.key == key }
    }

    /// Flows that still need attention (missed, or pending past their date).
    public var needsAttention: [PlannedFlow] {
        flows.filter { $0.status == .missed }
    }
}

public enum ProjectionEngine {
    /// Projects the budget over `horizon` (default: from the settings) as of `today`.
    /// With bank data whose accounts are counted in the total, the projection is anchored
    /// on the real balance and reconciled against the transactions.
    public static func run(document: BudgetDocument, today: LocalDate, horizon: DateSpan? = nil, bank: BankCache? = nil) -> Projection {
        let requested = horizon ?? PlanContext.defaultHorizon(settings: document.settings, today: today)
        let includedUp = Set(document.accounts.filter(\.includedInTotal).compactMap(\.upAccountID))
        let bankMode = bank.map { cache in cache.lastSync != nil && cache.accounts.contains { includedUp.contains($0.id) } } ?? false

        // Manual mode starts from the latest balance entered before the window so the total carries in.
        var computeStart = requested.start
        if !bankMode, let anchor = document.checkpoints.filter({ $0.date < requested.start }).max(by: { $0.date < $1.date }) {
            computeStart = anchor.date
        }
        let computeSpan = DateSpan(start: computeStart, end: requested.end)
        let context = PlanContext(document: document, today: today, horizon: computeSpan)

        var flows: [PlannedFlow] = []
        var envelopes: [EnvelopePeriod] = []
        for item in document.items {
            if item.isEnvelope {
                envelopes += EnvelopeAllocator.periods(for: item, context: context)
            } else {
                flows += OccurrenceGenerator.flows(for: item, context: context)
            }
        }
        let income = IncomeEngine.run(context: context)
        flows += income.flows
        flows.sort { ($0.date, $0.key) < ($1.date, $1.key) }

        var warnings: [String] = []
        for estimate in income.estimates where estimate.exceedsConcessionalCap {
            warnings.append("Planned super for \(estimate.year.label) (\(MoneyFormat.string(estimate.concessionalContributions, showCents: false))) is over the \(MoneyFormat.string(estimate.concessionalCap, showCents: false)) concessional cap.")
        }

        if bankMode, let bank {
            return bankProjection(document: document, bank: bank, includedUp: includedUp, today: today, horizon: requested,
                                  flows: flows, envelopes: envelopes, income: income, warnings: warnings)
        }

        let allDays = ledger(span: computeSpan, flows: flows, envelopes: envelopes, checkpoints: document.checkpoints)
        let offset = requested.start - computeSpan.start
        return Projection(
            today: today,
            horizon: requested,
            mode: .manual,
            flows: flows.filter { requested.contains($0.date) },
            envelopes: envelopes.filter { $0.span.overlaps(requested) },
            payEvents: income.events.filter { requested.contains($0.payDate) },
            estimates: income.estimates,
            days: Array(allDays[offset...]),
            warnings: warnings,
            unplanned: [],
            bankBalance: nil,
            bankBalanceDate: nil
        )
    }

    /// Daily totals and running balance, anchored by checkpoints (manual mode).
    static func ledger(span: DateSpan, flows: [PlannedFlow], envelopes: [EnvelopePeriod], checkpoints: [BalanceCheckpoint]) -> [DayLedger] {
        let count = span.dayCount
        var inflow = [Money](repeating: .zero, count: count)
        var outflow = [Money](repeating: .zero, count: count)
        for flow in flows where span.contains(flow.date) && !flow.amount.isZero {
            let index = flow.date - span.start
            if flow.amount.isPositive { inflow[index] += flow.amount } else { outflow[index] -= flow.amount }
        }
        for envelope in envelopes {
            for allocation in envelope.allocations where span.contains(allocation.date) {
                outflow[allocation.date - span.start] += allocation.amount
            }
        }
        var anchors: [Int32: Money] = [:]
        for checkpoint in checkpoints { anchors[checkpoint.date.dayNumber] = checkpoint.amount }

        var result: [DayLedger] = []
        result.reserveCapacity(count)
        var balance: Money?
        for index in 0..<count {
            let date = span.start.adding(days: index)
            let checkpoint = anchors[date.dayNumber]
            let opening = checkpoint ?? balance
            let closing = opening.map { $0 + inflow[index] - outflow[index] }
            balance = closing
            result.append(DayLedger(date: date, inflow: inflow[index], outflow: outflow[index],
                                    opening: opening, closing: closing, checkpoint: checkpoint, isActual: false))
        }
        return result
    }

    // MARK: Bank mode

    private static func bankProjection(
        document: BudgetDocument, bank: BankCache, includedUp: Set<String>, today: LocalDate, horizon: DateSpan,
        flows plannedFlows: [PlannedFlow], envelopes plannedEnvelopes: [EnvelopePeriod], income: IncomeResult, warnings: [String]
    ) -> Projection {
        let zone = document.settings.timeZone
        let anchorDate = min(today, bank.lastSync.map(zone.localDate(for:)) ?? today)
        let balance = bank.accounts.filter { includedUp.contains($0.id) }.reduce(Money.zero) { $0 + $1.balance }
        let coverage = bank.coverageStart.map(zone.localDate(for:))

        // Transactions on counted accounts. Transfers between counted accounts cancel out.
        let counted = bank.transactions.filter { includedUp.contains($0.accountID) }
            .map { DatedTransaction(transaction: $0, date: zone.localDate(for: $0.createdAt)) }
        let external = counted.filter { !($0.transaction.transferAccountID.map(includedUp.contains) ?? false) }

        let options = ReconcileOptions(today: today, graceDays: document.settings.graceDays, coverageStart: coverage, anchorDate: anchorDate)
        let reconciliation = Reconciler.reconcile(flows: plannedFlows, envelopes: plannedEnvelopes, transactions: external,
                                                  document: document, bank: bank, options: options)

        let flows = plannedFlows.map { flow -> PlannedFlow in
            var copy = flow
            copy.reconciliation = reconciliation.flows[flow.key]
            return copy
        }

        // Envelopes: actual spending so far, and what's left spread over the rest of the period.
        let envelopes = plannedEnvelopes.map { period -> EnvelopePeriod in
            var copy = period
            let spend = reconciliation.envelopes[period.key] ?? EnvelopeSpend()
            copy.spend = spend
            if period.span.end < today {
                copy.allocations = []
            } else if period.span.start <= today {
                let remainingDays = period.allocations.map(\.date).filter { $0 >= today }
                let remaining = max(.zero, period.budget - spend.spent)
                copy.allocations = remainingDays.isEmpty || remaining.isZero ? [] :
                    zip(remainingDays, remaining.split(remainingDays.count)).map { DayAmount(date: $0.0, amount: $0.1) }
            }
            return copy
        }

        let count = horizon.dayCount
        var inflow = [Money](repeating: .zero, count: count)
        var outflow = [Money](repeating: .zero, count: count)
        var plannedNet = [Money](repeating: .zero, count: count)
        func add(_ amount: Money, on date: LocalDate, planned: Bool) {
            guard horizon.contains(date), !amount.isZero else { return }
            let index = date - horizon.start
            if amount.isPositive { inflow[index] += amount } else { outflow[index] -= amount }
            if planned { plannedNet[index] += amount }
        }

        // Real money in and out, up to the anchor day.
        for dated in external where dated.date <= anchorDate {
            add(dated.transaction.balanceDelta, on: dated.date, planned: false)
        }
        // Planned flows that haven't happened yet.
        for flow in flows where flow.state == .planned {
            switch flow.status {
            case .matched?, .markedPaid?, .assumed?, .missed?:
                continue
            case .pending?:
                add(flow.amount, on: max(today, anchorDate), planned: true)
            case .upcoming?, nil:
                if flow.date >= anchorDate { add(flow.amount, on: flow.date, planned: true) }
            }
        }
        for envelope in envelopes {
            for allocation in envelope.allocations where allocation.date >= anchorDate {
                add(-allocation.amount, on: allocation.date, planned: true)
            }
        }

        // Balances: work back from the bank balance for past days, forward with the plan after.
        var closing = [Money?](repeating: nil, count: count)
        var afterDelta = Money.zero // sum of balance changes dated after the day being filled
        let deltasByDay = Dictionary(grouping: counted, by: \.date).mapValues { $0.reduce(Money.zero) { $0 + $1.transaction.balanceDelta } }
        let futureDeltas = counted.filter { $0.date > anchorDate }.reduce(Money.zero) { $0 + $1.transaction.balanceDelta }
        afterDelta = futureDeltas
        var date = anchorDate
        while date >= horizon.start {
            if let index = horizon.contains(date) ? date - horizon.start : nil {
                if coverage.map({ date >= $0.adding(days: -1) }) ?? true {
                    closing[index] = balance - afterDelta
                }
            }
            afterDelta += deltasByDay[date] ?? .zero
            date = date.adding(days: -1)
        }
        if horizon.contains(anchorDate) {
            let index = anchorDate - horizon.start
            closing[index] = (closing[index] ?? balance) + plannedNet[index]
        }
        var running = horizon.contains(anchorDate) ? closing[anchorDate - horizon.start] : (anchorDate < horizon.start ? balance : nil)
        var day = max(anchorDate.adding(days: 1), horizon.start)
        while day <= horizon.end {
            let index = day - horizon.start
            running = running.map { $0 + plannedNet[index] }
            closing[index] = running
            day = day.adding(days: 1)
        }

        var days: [DayLedger] = []
        days.reserveCapacity(count)
        for index in 0..<count {
            let date = horizon.start.adding(days: index)
            let opening: Money?
            if index > 0 {
                opening = closing[index - 1]
            } else {
                opening = closing[0].map { $0 - (inflow[0] - outflow[0]) }
            }
            days.append(DayLedger(date: date, inflow: inflow[index], outflow: outflow[index], opening: opening,
                                  closing: closing[index], checkpoint: nil, isActual: date < anchorDate))
        }

        var allWarnings = warnings
        let missed = flows.filter { $0.status == .missed }
        if !missed.isEmpty {
            allWarnings.append("\(missed.count) planned item\(missed.count == 1 ? " hasn't" : "s haven't") shown up at the bank. Check them in the grid.")
        }

        return Projection(
            today: today,
            horizon: horizon,
            mode: .bank,
            flows: flows.filter { horizon.contains($0.date) || ($0.status == .pending && horizon.contains(today)) },
            envelopes: envelopes.filter { $0.span.overlaps(horizon) },
            payEvents: income.events.filter { horizon.contains($0.payDate) },
            estimates: income.estimates,
            days: days,
            warnings: allWarnings,
            unplanned: reconciliation.unplanned.filter { horizon.contains($0.date) },
            assignments: reconciliation.assignments,
            bankBalance: balance,
            bankBalanceDate: anchorDate
        )
    }
}
