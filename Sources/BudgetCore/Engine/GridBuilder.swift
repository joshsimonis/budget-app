import Foundation

public enum CellStatus: String, Hashable, Sendable {
    case empty
    /// Expected (shown as a normal amount).
    case planned
    case skipped
    case paused
    case unpaid
    /// Reconciled against a bank transaction.
    case matched
    /// Overdue but still within the grace period.
    case pending
    /// Overdue past the grace period with no matching transaction.
    case missed
    /// Real bank data with nothing planned (e.g. unplanned spending).
    case actual
}

public struct GridCell: Hashable, Sendable {
    /// Display amount (always positive; the row says whether it's money in or out). Nil = blank.
    public var amount: Money?
    public var status: CellStatus
    /// The occurrences behind this cell (for the editor popover).
    public var keys: [OccurrenceKey]
    public var isOverridden: Bool
    /// Envelope rows: actual spending so far in this column (when bank data is available).
    public var envelopeSpent: Money?

    public init(amount: Money? = nil, status: CellStatus = .empty, keys: [OccurrenceKey] = [], isOverridden: Bool = false, envelopeSpent: Money? = nil) {
        self.amount = amount
        self.status = status
        self.keys = keys
        self.isOverridden = isOverridden
        self.envelopeSpent = envelopeSpent
    }

    public static let empty = GridCell()
}

public enum RowKind: String, Hashable, Sendable {
    case item, envelope, income, setAside, other
}

public struct GridRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var kind: RowKind
    public var sourceID: UUID?
    public var isInflow: Bool
    public var periodID: UUID?
    public var cells: [GridCell]

    public func hasValue(in range: Range<Int>) -> Bool {
        range.contains { cells.indices.contains($0) && cells[$0].status != .empty }
    }
}

public struct GridSection: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case period, account, unassigned, oneOffs, setAsides, income, other
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var color: PeriodColor?
    public var rows: [GridRow]
    /// Only rows with something in the visible columns are shown (one-offs).
    public var hidesEmptyRows: Bool
}

/// The rows under the grid, like the sheet's Total / Cash / Net rows.
public struct GridSummary: Hashable, Sendable {
    public var totalOut: [Money]
    public var totalIn: [Money]
    public var opening: [Money?]
    public var closing: [Money?]
    /// A balance you entered within the column (the first one).
    public var checkpoint: [Money?]
    public var lowest: [Money?]

    public func net(_ index: Int) -> Money { totalIn[index] - totalOut[index] }
}

public struct PeriodBand: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: PeriodColor
    public var firstBucket: Int
    public var lastBucket: Int
}

/// Everything the Cash Flow grid displays.
public struct CashFlowGrid: Sendable {
    public var granularity: Granularity
    public var buckets: [Bucket]
    public var sections: [GridSection]
    public var summary: GridSummary
    public var bands: [PeriodBand]
    public var currentBucket: Int?

    public func bucketIndex(containing date: LocalDate) -> Int? {
        var low = 0
        var high = buckets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let span = buckets[mid].span
            if date < span.start { high = mid - 1 } else if date > span.end { low = mid + 1 } else { return mid }
        }
        return nil
    }

    public func row(_ id: String) -> GridRow? {
        for section in sections {
            if let row = section.rows.first(where: { $0.id == id }) { return row }
        }
        return nil
    }
}

public enum GridBuilder {
    public static func rowID(for key: OccurrenceKey, kind: FlowKind) -> String {
        switch kind {
        case .item: "item:\(key.sourceID.uuidString)"
        case .pay: "income:\(key.sourceID.uuidString)"
        case .taxSetAside: "tax:\(key.sourceID.uuidString)"
        case .gstSetAside: "gst:\(key.sourceID.uuidString)"
        }
    }

    private struct Accumulator {
        var cents: [Int64]
        var hasPlanned: [Bool]
        var state: [FlowState?]
        var keys: [[OccurrenceKey]]
        var overridden: [Bool]

        init(count: Int) {
            cents = Array(repeating: 0, count: count)
            hasPlanned = Array(repeating: false, count: count)
            state = Array(repeating: nil, count: count)
            keys = Array(repeating: [], count: count)
            overridden = Array(repeating: false, count: count)
        }

        func cells() -> [GridCell] {
            cents.indices.map { index in
                if hasPlanned[index] {
                    return GridCell(amount: Money(cents: cents[index]), status: .planned, keys: keys[index], isOverridden: overridden[index])
                }
                if let state = state[index] {
                    let status: CellStatus = switch state {
                    case .planned: .planned
                    case .skipped: .skipped
                    case .paused: .paused
                    case .unpaid: .unpaid
                    }
                    return GridCell(amount: nil, status: status, keys: keys[index], isOverridden: overridden[index])
                }
                return .empty
            }
        }
    }

    public static func build(_ projection: Projection, document: BudgetDocument, granularity: Granularity) -> CashFlowGrid {
        let horizon = projection.horizon
        let buckets = Bucketing.buckets(for: horizon, granularity: granularity, today: projection.today)
        var bucketOfDay = [Int](repeating: 0, count: horizon.dayCount)
        for bucket in buckets {
            for date in bucket.span.dates { bucketOfDay[date - horizon.start] = bucket.index }
        }
        func bucket(of date: LocalDate) -> Int? {
            horizon.contains(date) ? bucketOfDay[date - horizon.start] : nil
        }

        var accumulators: [String: Accumulator] = [:]
        func add(_ rowID: String, _ body: (inout Accumulator) -> Void) {
            var acc = accumulators[rowID] ?? Accumulator(count: buckets.count)
            body(&acc)
            accumulators[rowID] = acc
        }

        for flow in projection.flows {
            guard let b = bucket(of: flow.date) else { continue }
            add(rowID(for: flow.key, kind: flow.kind)) { acc in
                if flow.state == .planned {
                    acc.cents[b] += flow.amount.magnitude.cents
                    acc.hasPlanned[b] = true
                } else if acc.state[b] == nil {
                    acc.state[b] = flow.state
                }
                acc.keys[b].append(flow.key)
                if flow.isOverridden { acc.overridden[b] = true }
            }
        }

        for envelope in projection.envelopes {
            let rowID = "item:\(envelope.itemID.uuidString)"
            add(rowID) { acc in
                for allocation in envelope.allocations {
                    guard let b = bucket(of: allocation.date) else { continue }
                    acc.cents[b] += allocation.amount.cents
                    acc.hasPlanned[b] = true
                }
                guard let visible = envelope.span.intersection(horizon),
                      let first = bucket(of: visible.start), let last = bucket(of: visible.end) else { return }
                for b in first...last {
                    acc.keys[b].append(envelope.key)
                    if envelope.isOverridden { acc.overridden[b] = true }
                    if envelope.state != .planned && acc.state[b] == nil { acc.state[b] = envelope.state }
                }
            }
        }

        let today = projection.today
        func cells(_ rowID: String) -> [GridCell] {
            accumulators[rowID]?.cells() ?? Array(repeating: .empty, count: buckets.count)
        }
        func itemRow(_ item: BudgetItem) -> GridRow {
            let id = "item:\(item.id.uuidString)"
            return GridRow(
                id: id,
                title: item.name,
                subtitle: itemSubtitle(item, today: today),
                kind: item.isEnvelope ? .envelope : .item,
                sourceID: item.id,
                isInflow: item.flow == .inflow,
                periodID: item.periodID,
                cells: cells(id)
            )
        }
        let byOrder: (BudgetItem, BudgetItem) -> Bool = { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
        let items = document.items.filter { !$0.archived }

        var sections: [GridSection] = []

        for period in document.periods.sorted(by: { $0.span.start < $1.span.start }) {
            let rows = items.filter { $0.periodID == period.id }.sorted(by: byOrder).map(itemRow)
            guard !rows.isEmpty else { continue }
            sections.append(GridSection(id: "period:\(period.id.uuidString)", title: period.name, kind: .period,
                                        color: period.color, rows: rows, hidesEmptyRows: false))
        }

        let regular = items.filter { $0.periodID == nil && !$0.isOneOff }
        let knownAccounts = Set(document.accounts.map(\.id))
        for account in document.sortedAccounts {
            let rows = regular.filter { $0.flow == .outflow && $0.accountID == account.id }.sorted(by: byOrder).map(itemRow)
            guard !rows.isEmpty else { continue }
            sections.append(GridSection(id: "account:\(account.id.uuidString)", title: account.name, kind: .account,
                                        color: nil, rows: rows, hidesEmptyRows: false))
        }
        let unassigned = regular.filter { $0.flow == .outflow && ($0.accountID.map { !knownAccounts.contains($0) } ?? true) }
        if !unassigned.isEmpty {
            sections.append(GridSection(id: "unassigned", title: document.accounts.isEmpty ? "Spending" : "Other items",
                                        kind: .unassigned, color: nil, rows: unassigned.sorted(by: byOrder).map(itemRow), hidesEmptyRows: false))
        }

        let oneOffs = items.filter { $0.periodID == nil && $0.isOneOff }
        if !oneOffs.isEmpty {
            let rows = oneOffs.sorted { ($0.segments.first?.start ?? today, $0.name) < ($1.segments.first?.start ?? today, $1.name) }.map(itemRow)
            sections.append(GridSection(id: "oneoffs", title: "One-offs", kind: .oneOffs, color: nil, rows: rows, hidesEmptyRows: true))
        }

        var setAsideRows: [GridRow] = []
        for source in document.incomes where !source.archived {
            for (prefix, label) in [("tax", "Tax set-aside"), ("gst", "GST set-aside")] {
                let id = "\(prefix):\(source.id.uuidString)"
                guard accumulators[id] != nil else { continue }
                setAsideRows.append(GridRow(id: id, title: label, subtitle: source.name, kind: .setAside, sourceID: source.id,
                                            isInflow: false, periodID: nil, cells: cells(id)))
            }
        }
        if !setAsideRows.isEmpty {
            sections.append(GridSection(id: "setasides", title: "Set aside", kind: .setAsides, color: nil, rows: setAsideRows, hidesEmptyRows: false))
        }

        var incomeRows = regular.filter { $0.flow == .inflow }.sorted(by: byOrder).map(itemRow)
        for source in document.incomes.filter({ !$0.archived }).sorted(by: { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }) {
            let id = "income:\(source.id.uuidString)"
            incomeRows.append(GridRow(id: id, title: source.name, subtitle: incomeSubtitle(source, today: today), kind: .income,
                                      sourceID: source.id, isInflow: true, periodID: nil, cells: cells(id)))
        }
        if !incomeRows.isEmpty {
            sections.append(GridSection(id: "income", title: "Income", kind: .income, color: nil, rows: incomeRows, hidesEmptyRows: false))
        }

        // Summary rows from the daily ledger.
        var totalOut = [Money](repeating: .zero, count: buckets.count)
        var totalIn = [Money](repeating: .zero, count: buckets.count)
        var opening = [Money?](repeating: nil, count: buckets.count)
        var closing = [Money?](repeating: nil, count: buckets.count)
        var checkpoint = [Money?](repeating: nil, count: buckets.count)
        var lowest = [Money?](repeating: nil, count: buckets.count)
        for bucket in buckets {
            let first = bucket.span.start - horizon.start
            let last = bucket.span.end - horizon.start
            opening[bucket.index] = projection.days[first].opening
            closing[bucket.index] = projection.days[last].closing
            for day in projection.days[first...last] {
                totalOut[bucket.index] += day.outflow
                totalIn[bucket.index] += day.inflow
                if checkpoint[bucket.index] == nil, let value = day.checkpoint { checkpoint[bucket.index] = value }
                if let close = day.closing {
                    lowest[bucket.index] = lowest[bucket.index].map { min($0, close) } ?? close
                }
            }
        }

        var bands: [PeriodBand] = []
        let grid = CashFlowGrid(granularity: granularity, buckets: buckets, sections: [], summary: GridSummary(
            totalOut: totalOut, totalIn: totalIn, opening: opening, closing: closing, checkpoint: checkpoint, lowest: lowest
        ), bands: [], currentBucket: buckets.first(where: \.containsToday)?.index)
        for period in document.periods.sorted(by: { $0.span.start < $1.span.start }) {
            guard let visible = period.span.intersection(horizon),
                  let first = grid.bucketIndex(containing: visible.start),
                  let last = grid.bucketIndex(containing: visible.end) else { continue }
            bands.append(PeriodBand(id: period.id, name: period.name, color: period.color, firstBucket: first, lastBucket: last))
        }

        var result = grid
        result.sections = sections
        result.bands = bands
        return result
    }

    static func itemSubtitle(_ item: BudgetItem, today: LocalDate) -> String {
        guard let segment = item.segment(covering: today) ?? item.segments.first(where: { $0.start > today }) ?? item.segments.last else {
            return ""
        }
        let amount = MoneyFormat.string(segment.amount)
        if item.isEnvelope {
            return "Envelope · \(amount) \(segment.recurrence.rule.frequencyLabel.lowercased())"
        }
        if segment.recurrence.rule.unit == .once {
            return "\(item.flow == .inflow ? "+" : "")\(amount) on \(segment.recurrence.anchor.dayMonth(includeYear: true))"
        }
        return "\(segment.recurrence.label) · \(amount)"
    }

    static func incomeSubtitle(_ source: IncomeSource, today: LocalDate) -> String {
        let frequency = source.paySchedule.rule.frequencyLabel
        guard let rate = source.rate(on: today) else { return "\(source.kind.label) · \(frequency)" }
        return "\(MoneyFormat.string(rate.amount, showCents: false)) \(rate.unit.label) · paid \(frequency.lowercased())"
    }
}
