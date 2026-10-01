import Foundation

/// A regular payment (or regular money in) spotted in the bank history.
public struct RecurringSuggestion: Identifiable, Hashable, Sendable {
    /// Stable key (direction + merchant), used to dismiss it.
    public var key: String
    public var name: String
    public var flow: Flow
    public var recurrence: Recurrence
    public var firstDate: LocalDate
    public var lastDate: LocalDate
    public var nextDate: LocalDate
    /// Median amount (positive).
    public var typicalAmount: Money
    public var latestAmount: Money
    public var minimumAmount: Money
    public var maximumAmount: Money
    public var occurrences: Int
    /// The Up account it usually comes from or goes to.
    public var upAccountID: String
    /// For regular transfers to an account that isn't counted (e.g. a savings goal).
    public var counterpartyUpAccountID: String?
    /// 0…1
    public var confidence: Double
    public var patterns: [String]

    public var id: String { key }
    /// Amounts vary by more than 10%.
    public var isVariable: Bool {
        typicalAmount.cents > 0 && (maximumAmount - minimumAmount).cents * 10 > typicalAmount.cents
    }
}

/// Average spending in a category, as a starting point for an envelope.
public struct EnvelopeSuggestion: Identifiable, Hashable, Sendable {
    public var categoryID: String
    public var name: String
    public var parentName: String?
    public var weeklyAverage: Money
    public var weeks: Int
    public var transactionCount: Int

    public var id: String { categoryID }
}

public enum RecurringDetector {
    /// Lower-cased merchant text without numbers or punctuation: "Netflix.com 1234" → "netflix com".
    public static func merchantKey(_ description: String) -> String {
        var text = ""
        for scalar in description.lowercased().unicodeScalars {
            text.unicodeScalars.append(CharacterSet.letters.contains(scalar) ? scalar : " ")
        }
        let words = text.split(separator: " ").filter { $0.count > 1 }.map(String.init)
        return words.prefix(4).joined(separator: " ")
    }

    private struct Candidate: Sendable {
        let rule: RecurrenceRule
        let fits: @Sendable (LocalDate, LocalDate) -> Bool
    }

    private static let candidates: [Candidate] = [
        Candidate(rule: .weekly) { a, b in abs((b - a) - 7) <= 1 },
        Candidate(rule: .fortnightly) { a, b in abs((b - a) - 14) <= 2 },
        Candidate(rule: .fourWeekly) { a, b in abs((b - a) - 28) <= 2 },
        Candidate(rule: .monthly) { a, b in b.monthIndex - a.monthIndex == 1 && (26...35).contains(b - a) },
        Candidate(rule: .quarterly) { a, b in b.monthIndex - a.monthIndex == 3 && (84...98).contains(b - a) },
        Candidate(rule: .yearly) { a, b in b.monthIndex - a.monthIndex == 12 && (358...372).contains(b - a) },
    ]

    /// Regular payments in the last 13 months that are still going and aren't in the plan yet.
    public static func suggestions(bank: BankCache, document: BudgetDocument, today: LocalDate, timeZone: TimeZoneBridge) -> [RecurringSuggestion] {
        let included = Set(document.accounts.filter(\.includedInTotal).compactMap(\.upAccountID))
        let accounts = included.isEmpty ? Set(bank.accounts.map(\.id)) : included
        let since = today.adding(months: -13)
        let dismissed = Set(document.reconciliation.dismissedSuggestionKeys)
        let envelopeCategories = bank.expandCategories(document.items.compactMap(\.envelope).flatMap(\.categoryIDs))

        // Group by direction and merchant (or by the account money is transferred to).
        var groups: [String: [(BankTransaction, LocalDate)]] = [:]
        for transaction in bank.transactions where accounts.contains(transaction.accountID) && !transaction.amount.isZero {
            let date = timeZone.localDate(for: transaction.createdAt)
            guard date >= since else { continue }
            if let counterpart = transaction.transferAccountID, accounts.contains(counterpart) { continue }
            let direction = transaction.amount.isPositive ? "in" : "out"
            let merchant = transaction.transferAccountID.map { "transfer \($0)" } ?? merchantKey(transaction.description)
            guard !merchant.isEmpty else { continue }
            groups["\(direction):\(merchant)", default: []].append((transaction, date))
        }

        var result: [RecurringSuggestion] = []
        for (key, entries) in groups where !dismissed.contains(key) {
            let sorted = entries.sorted { ($0.1, $0.0.createdAt) < ($1.1, $1.0.createdAt) }
            // One occurrence per day (several on the same day are combined).
            var days: [(LocalDate, Money, BankTransaction)] = []
            for (transaction, date) in sorted {
                if let last = days.last, last.0 == date {
                    days[days.count - 1].1 += transaction.amount.magnitude
                    days[days.count - 1].2 = transaction
                } else {
                    days.append((date, transaction.amount.magnitude, transaction))
                }
            }
            guard days.count >= 2 else { continue }
            let latest = days[days.count - 1].2
            if let category = latest.categoryID, envelopeCategories.contains(category) { continue }
            if document.items.contains(where: { item in
                guard let rule = item.match else { return false }
                return TextMatch.matches(rule.patterns, latest) || (rule.counterpartyUpAccountID != nil && rule.counterpartyUpAccountID == latest.transferAccountID)
            }) { continue }
            if latest.amount.isPositive, document.incomes.contains(where: { TextMatch.matches($0.match?.patterns ?? [], latest) }) { continue }

            // Pick the schedule that fits the most gaps.
            var best: (Candidate, Double)?
            for candidate in candidates {
                let pairs = zip(days, days.dropFirst())
                let fitting = pairs.filter { candidate.fits($0.0, $1.0) }.count
                let fraction = Double(fitting) / Double(days.count - 1)
                if best == nil || fraction > best!.1 + 0.0001 { best = (candidate, fraction) }
            }
            guard let (candidate, fit) = best else { continue }
            let minimum = candidate.rule.unit == .year ? 2 : 3
            guard days.count >= minimum, fit >= 0.6 else { continue }

            // Still going: the last one was within about 1.5 periods.
            let period = Int(candidate.rule.approximateDays.rounded())
            let lastDate = days[days.count - 1].0
            guard today - lastDate <= period + period / 2 + 3 else { continue }

            var amounts = days.map(\.1).sorted()
            let median = amounts[amounts.count / 2]
            amounts = days.map(\.1)
            let recurrence: Recurrence
            if candidate.rule.unit == .month || candidate.rule.unit == .year {
                // Use the most common day of the month, so weekend shifts don't move the anchor.
                let dayCounts = Dictionary(grouping: days.map(\.0.day), by: { $0 }).mapValues(\.count)
                let day = dayCounts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? lastDate.day
                let anchorDay = min(day, LocalDate.daysInMonth(year: lastDate.year, month: lastDate.month))
                recurrence = Recurrence(candidate.rule, anchor: LocalDate(lastDate.year, lastDate.month, anchorDay))
            } else {
                recurrence = Recurrence(candidate.rule, anchor: lastDate)
            }
            let next = recurrence.next(onOrAfter: max(today, lastDate.adding(days: 1))) ?? today
            let confidence = min(1, fit * min(1, Double(days.count) / 6) * (days.count >= 4 ? 1 : 0.85))
            let counterparty = latest.transferAccountID
            result.append(RecurringSuggestion(
                key: key,
                name: latest.description,
                flow: latest.amount.isPositive ? .inflow : .outflow,
                recurrence: recurrence,
                firstDate: days[0].0,
                lastDate: lastDate,
                nextDate: next,
                typicalAmount: median,
                latestAmount: amounts[amounts.count - 1],
                minimumAmount: amounts.min() ?? median,
                maximumAmount: amounts.max() ?? median,
                occurrences: days.count,
                upAccountID: latest.accountID,
                counterpartyUpAccountID: counterparty,
                confidence: confidence,
                patterns: counterparty == nil ? [TextMatch.normalize(latest.description)] : []
            ))
        }
        return result.sorted { ($0.confidence, $0.typicalAmount.cents, $0.key) > ($1.confidence, $1.typicalAmount.cents, $1.key) }
    }

    /// Average weekly spending per Up category over the last `weeks` weeks, for categories
    /// that no envelope covers yet (spending already matched to bills is left out).
    public static func envelopeSuggestions(bank: BankCache, document: BudgetDocument, today: LocalDate, timeZone: TimeZoneBridge, weeks: Int = 12) -> [EnvelopeSuggestion] {
        let included = Set(document.accounts.filter(\.includedInTotal).compactMap(\.upAccountID))
        let accounts = included.isEmpty ? Set(bank.accounts.map(\.id)) : included
        let covered = bank.expandCategories(document.items.compactMap(\.envelope).flatMap(\.categoryIDs))
        let span = DateSpan(start: today.adding(days: -7 * weeks), end: today.adding(days: -1))
        let billPatterns = document.items.filter { !$0.isEnvelope }.compactMap(\.match).flatMap(\.patterns)
        var totals: [String: (Money, Int)] = [:]
        for transaction in bank.transactions where accounts.contains(transaction.accountID) && !transaction.isTransfer {
            guard let category = transaction.categoryID, !covered.contains(category),
                  span.contains(timeZone.localDate(for: transaction.createdAt)),
                  !TextMatch.matches(billPatterns, transaction) else { continue }
            let current = totals[category] ?? (.zero, 0)
            totals[category] = (current.0 - transaction.amount, current.1 + 1)
        }
        return totals.compactMap { category, value in
            let weekly = value.0.scaled(1, Int64(weeks))
            guard weekly.cents >= 1000 else { return nil }
            let info = bank.category(category)
            return EnvelopeSuggestion(
                categoryID: category,
                name: info?.name ?? category,
                parentName: bank.category(info?.parentID)?.name,
                weeklyAverage: weekly,
                weeks: weeks,
                transactionCount: value.1
            )
        }
        .sorted { ($0.weeklyAverage.cents, $0.categoryID) > ($1.weeklyAverage.cents, $1.categoryID) }
    }

    /// A ready-to-add budget item for a suggestion. Past occurrences in the bank history line up.
    public static func makeItem(_ suggestion: RecurringSuggestion, document: BudgetDocument) -> BudgetItem {
        BudgetItem(
            name: suggestion.name,
            flow: suggestion.flow,
            accountID: document.accounts.first { $0.upAccountID == suggestion.upAccountID }?.id,
            segments: [ScheduleSegment(start: suggestion.firstDate, recurrence: suggestion.recurrence,
                                       amount: suggestion.isVariable ? suggestion.latestAmount : suggestion.typicalAmount)],
            match: MatchRule(patterns: suggestion.patterns, counterpartyUpAccountID: suggestion.counterpartyUpAccountID,
                             toleranceBasisPoints: suggestion.isVariable ? 3000 : nil)
        )
    }

    /// A weekly envelope for a category, rounded up to the next $5.
    public static func makeEnvelope(_ suggestion: EnvelopeSuggestion, document: BudgetDocument, today: LocalDate) -> BudgetItem {
        let rounded = Money.dollars((suggestion.weeklyAverage.cents + 499) / 500 * 5)
        return BudgetItem(
            name: suggestion.name,
            accountID: document.sortedAccounts.first { $0.upAccountID != nil }?.id ?? document.sortedAccounts.first?.id,
            envelope: EnvelopeRule(categoryIDs: [suggestion.categoryID]),
            segments: [ScheduleSegment(start: today.startOfWeek, recurrence: Recurrence(.weekly, anchor: today.startOfWeek), amount: rounded)]
        )
    }
}
