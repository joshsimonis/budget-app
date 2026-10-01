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
    /// A balance you entered for the start of this day.
    public var checkpoint: Money?
    /// True for days whose figures come from real bank data.
    public var isActual: Bool

    public var net: Money { inflow - outflow }
}

/// Everything the app shows, computed from the document (and bank data, when connected).
public struct Projection: Sendable {
    public var today: LocalDate
    public var horizon: DateSpan
    public var flows: [PlannedFlow]
    public var envelopes: [EnvelopePeriod]
    public var payEvents: [PayEvent]
    public var estimates: [AnnualTaxEstimate]
    /// One per day of the horizon.
    public var days: [DayLedger]
    public var warnings: [String]

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
}

public enum ProjectionEngine {
    /// Projects the budget over `horizon` (default: from the settings) as of `today`.
    public static func run(document: BudgetDocument, today: LocalDate, horizon: DateSpan? = nil) -> Projection {
        let requested = horizon ?? PlanContext.defaultHorizon(settings: document.settings, today: today)
        // Start from the latest balance you entered before the window, so the running total carries in.
        var computeStart = requested.start
        if let anchor = document.checkpoints.filter({ $0.date < requested.start }).max(by: { $0.date < $1.date }) {
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

        let allDays = ledger(span: computeSpan, flows: flows, envelopes: envelopes, checkpoints: document.checkpoints)
        let offset = requested.start - computeSpan.start
        let days = Array(allDays[offset...])

        var warnings: [String] = []
        for estimate in income.estimates where estimate.exceedsConcessionalCap {
            warnings.append("Planned super for \(estimate.year.label) (\(MoneyFormat.string(estimate.concessionalContributions, showCents: false))) is over the \(MoneyFormat.string(estimate.concessionalCap, showCents: false)) concessional cap.")
        }

        return Projection(
            today: today,
            horizon: requested,
            flows: flows.filter { requested.contains($0.date) },
            envelopes: envelopes.filter { $0.span.overlaps(requested) },
            payEvents: income.events.filter { requested.contains($0.payDate) },
            estimates: income.estimates,
            days: days,
            warnings: warnings
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
}
