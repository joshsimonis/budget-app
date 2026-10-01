import BudgetCore
import Foundation

enum ItemKind: String, CaseIterable, Identifiable {
    case bill, envelope, oneOff, moneyIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bill: "Bill or regular payment"
        case .envelope: "Envelope (flexible spending)"
        case .oneOff: "One-off"
        case .moneyIn: "Regular money in"
        }
    }

    var shortLabel: String {
        switch self {
        case .bill: "Bill"
        case .envelope: "Envelope"
        case .oneOff: "One-off"
        case .moneyIn: "Money in"
        }
    }

    static func of(_ item: BudgetItem) -> ItemKind {
        if item.isOneOff { return .oneOff }
        if item.isEnvelope { return .envelope }
        return item.flow == .inflow ? .moneyIn : .bill
    }
}

/// Editable copy of a budget item. The form edits the "current" schedule segment; price
/// changes over time are applied to `working` and everything is saved at once.
struct ItemDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var working: BudgetItem
    var currentSegmentID: UUID?

    var name: String
    var kind: ItemKind
    var accountID: UUID?
    var periodID: UUID?
    var amount: Money
    var unit: RecurrenceRule.Unit
    var interval: Int
    var monthEnd: Bool
    var anchor: LocalDate
    var adjustment: BusinessDayAdjustment
    var alreadyRunning: Bool
    var hasEnd: Bool
    var end: LocalDate
    var oneOffInflow: Bool
    var categories: String
    var tags: String
    var patterns: String
    var notes: String

    init(newKind kind: ItemKind, today: LocalDate, accountID: UUID? = nil, periodID: UUID? = nil, anchor: LocalDate? = nil) {
        id = UUID()
        isNew = true
        working = BudgetItem(id: id, name: "", segments: [])
        currentSegmentID = nil
        name = ""
        self.kind = kind
        self.accountID = accountID
        self.periodID = periodID
        amount = .zero
        unit = kind == .envelope || kind == .moneyIn ? .week : .month
        interval = 1
        monthEnd = false
        self.anchor = anchor ?? (kind == .envelope ? today.startOfWeek : today)
        adjustment = .none
        alreadyRunning = kind != .oneOff
        hasEnd = false
        end = today.adding(months: 12)
        oneOffInflow = false
        categories = ""
        tags = ""
        patterns = ""
        notes = ""
    }

    init(item: BudgetItem, today: LocalDate) {
        id = item.id
        isNew = false
        working = item
        let current = item.segment(covering: today) ?? item.segments.first { $0.start > today } ?? item.segments.last
        currentSegmentID = current?.id
        name = item.name
        kind = ItemKind.of(item)
        accountID = item.accountID
        periodID = item.periodID
        amount = current?.amount ?? .zero
        unit = current?.recurrence.rule.unit == .once ? .month : (current?.recurrence.rule.unit ?? .month)
        interval = current?.recurrence.rule.interval ?? 1
        monthEnd = current?.recurrence.rule.monthEnd ?? false
        anchor = current.map { segment in
            segment.recurrence.rule.unit == .once ? segment.recurrence.anchor : (segment.recurrence.next(onOrAfter: today) ?? segment.recurrence.anchor)
        } ?? today
        adjustment = current?.recurrence.adjustment ?? .none
        alreadyRunning = true
        hasEnd = item.segments.last?.end != nil && !item.isOneOff
        end = item.segments.last?.end ?? today.adding(months: 12)
        oneOffInflow = item.flow == .inflow
        categories = item.envelope?.categoryIDs.joined(separator: ", ") ?? ""
        tags = item.envelope?.tagIDs.joined(separator: ", ") ?? ""
        patterns = item.match?.patterns.joined(separator: ", ") ?? ""
        notes = item.notes
    }

    var rule: RecurrenceRule {
        RecurrenceRule(unit: unit, interval: interval, monthEnd: (unit == .month || unit == .year) && monthEnd)
    }

    var recurrence: Recurrence {
        kind == .oneOff ? .once(anchor) : Recurrence(rule, anchor: anchor, adjustment: adjustment)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (!hasEnd || end >= anchor || kind == .oneOff)
    }

    /// Adds a price change from `date` to the working copy (applied on save).
    mutating func addChange(from date: LocalDate, amount: Money) {
        applyFormToWorking(historyStart: date)
        ItemEdits.changeFrom(date, in: &working, amount: amount)
        if let segment = working.segment(covering: date) {
            currentSegmentID = segment.id
            self.amount = segment.amount
        }
    }

    mutating func removeSegment(_ id: UUID) {
        guard working.segments.count > 1, let index = working.segments.firstIndex(where: { $0.id == id }) else { return }
        let removed = working.segments.remove(at: index)
        if index > 0 {
            // The previous segment carries on through the removed one's dates.
            working.segments[index - 1].end = removed.end
        } else {
            working.segments[0].start = removed.start
        }
        ItemEdits.normalize(&working)
        if currentSegmentID == id { currentSegmentID = working.segments.last?.id }
    }

    /// The finished item.
    func build(historyStart: LocalDate) -> BudgetItem {
        var draft = self
        draft.applyFormToWorking(historyStart: historyStart)
        ItemEdits.removeOrphans(in: &draft.working)
        return draft.working
    }

    private static func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private mutating func applyFormToWorking(historyStart: LocalDate) {
        working.name = name.trimmingCharacters(in: .whitespaces)
        working.accountID = accountID
        working.periodID = periodID
        working.notes = notes
        working.flow = (kind == .moneyIn || (kind == .oneOff && oneOffInflow)) ? .inflow : .outflow
        working.envelope = kind == .envelope ? EnvelopeRule(categoryIDs: Self.split(categories), tagIDs: Self.split(tags)) : nil
        let patternList = Self.split(patterns)
        working.match = patternList.isEmpty && working.match?.counterpartyUpAccountID == nil
            ? nil
            : MatchRule(patterns: patternList, counterpartyUpAccountID: working.match?.counterpartyUpAccountID,
                        toleranceBasisPoints: working.match?.toleranceBasisPoints)

        if kind == .oneOff {
            let existingID = working.isOneOff ? working.segments.first?.id : nil
            var segment = ScheduleSegment.once(anchor, amount: amount)
            if let existingID { segment.id = existingID }
            working.segments = [segment]
            return
        }

        if working.segments.isEmpty || working.isOneOff {
            let start = alreadyRunning ? min(anchor, historyStart) : anchor
            let segment = ScheduleSegment(start: start, end: hasEnd ? end : nil, recurrence: recurrence, amount: amount)
            working.segments = [segment]
            currentSegmentID = segment.id
            return
        }

        if let index = working.segments.firstIndex(where: { $0.id == currentSegmentID }) ?? working.segments.indices.last {
            working.segments[index].amount = amount
            // Keep the phase if only the anchor's position moved along the same schedule.
            let old = working.segments[index].recurrence
            if old.rule != rule || old.adjustment != adjustment || !old.isOccurrence(anchor) {
                working.segments[index].recurrence = recurrence
            }
        }
        if let last = working.segments.indices.last {
            working.segments[last].end = hasEnd ? max(end, working.segments[last].start) : nil
        }
    }
}
