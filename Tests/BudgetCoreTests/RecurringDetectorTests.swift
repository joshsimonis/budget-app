import Foundation
import Testing
@testable import BudgetCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }

@Suite struct RecurringDetectorTests {
    let zone = TimeZoneBridge()
    let today = d(2026, 10, 1)

    private func t(_ id: String, _ date: LocalDate, _ cents: Int64, _ description: String, account: String = "acc-s",
                   category: String? = nil, transferTo: String? = nil) -> BankTransaction {
        BankTransaction(id: id, accountID: account, status: .settled,
                        createdAt: zone.startOfDay(date).addingTimeInterval(10 * 3600),
                        description: description, amount: Money(cents: cents), categoryID: category, transferAccountID: transferTo)
    }

    private var history: [BankTransaction] {
        var result: [BankTransaction] = []
        // Monthly on the 15th; Nov 2025 and Mar 2026 land on weekends and come out on the Monday.
        for (index, date) in [d(2025, 10, 15), d(2025, 11, 17), d(2025, 12, 15), d(2026, 1, 15), d(2026, 2, 16), d(2026, 3, 16),
                              d(2026, 4, 15), d(2026, 5, 15), d(2026, 6, 15), d(2026, 7, 15), d(2026, 8, 17), d(2026, 9, 15)].enumerated() {
            result.append(t("stream\(index)", date, -2299, "Streamflix.com 4417"))
        }
        // Fortnightly gym.
        var gym = d(2026, 5, 7)
        var n = 0
        while gym < today {
            result.append(t("gym\(n)", gym, -2600, "Gym Club"))
            gym = gym.adding(days: 14)
            n += 1
        }
        // Cancelled in March.
        for (index, month) in [11, 12].enumerated() { result.append(t("old\(index)", d(2025, month, 3), -999, "Old Sub")) }
        for (index, month) in [1, 2, 3].enumerated() { result.append(t("old\(index + 2)", d(2026, month, 3), -999, "Old Sub")) }
        // Irregular groceries.
        for (index, offset) in [2, 5, 6, 11, 19, 20, 24, 33, 35, 41, 50, 52, 57, 63, 66, 75, 80].enumerated() {
            result.append(t("groc\(index)", today.adding(days: -offset), -Int64(3000 + index * 731 % 5000), "Fresh Grocer", category: "groceries"))
        }
        // Weekly pay on Wednesdays.
        var pay = d(2026, 6, 3)
        n = 0
        while pay < today {
            result.append(t("pay\(n)", pay, 249_800, "Salary Example Pty"))
            pay = pay.adding(days: 7)
            n += 1
        }
        // Weekly transfer to a saver that isn't counted.
        var save = d(2026, 7, 6)
        n = 0
        while save < today {
            result.append(t("save\(n)", save, -5000, "Transfer to Holiday", transferTo: "acc-holiday"))
            save = save.adding(days: 7)
            n += 1
        }
        return result
    }

    private var bank: BankCache {
        BankCache(
            accounts: [BankAccount(id: "acc-s", name: "Spending", accountType: "TRANSACTIONAL", ownershipType: "INDIVIDUAL", balance: .dollars(1000)),
                       BankAccount(id: "acc-holiday", name: "Holiday", accountType: "SAVER", ownershipType: "INDIVIDUAL", balance: .dollars(1000))],
            transactions: history.sorted { $0.createdAt < $1.createdAt },
            categories: [BankCategory(id: "groceries", name: "Groceries", parentID: "home"), BankCategory(id: "home", name: "Home")]
        )
    }

    private var document: BudgetDocument {
        BudgetDocument(accounts: [Account(name: "Spending", upAccountID: "acc-s"), Account(name: "Holiday", upAccountID: "acc-holiday", includedInTotal: false)])
    }

    @Test func merchantKeys() {
        #expect(RecurringDetector.merchantKey("Streamflix.com 4417") == "streamflix com")
        #expect(RecurringDetector.merchantKey("PAYPAL *SPOTIFY 12345 SYDNEY") == "paypal spotify sydney")
    }

    @Test func findsTheRegularOnes() throws {
        let found = RecurringDetector.suggestions(bank: bank, document: document, today: today, timeZone: zone)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })

        let stream = try #require(byName["Streamflix.com 4417"])
        #expect(stream.recurrence.rule == .monthly)
        #expect(stream.recurrence.anchor.day == 15)
        #expect(stream.nextDate == d(2026, 10, 15))
        #expect(stream.typicalAmount == Money(cents: 2299))
        #expect(!stream.isVariable)
        #expect(stream.patterns == ["streamflix.com 4417"])

        let gym = try #require(byName["Gym Club"])
        #expect(gym.recurrence.rule == .fortnightly)

        let pay = try #require(byName["Salary Example Pty"])
        #expect(pay.flow == .inflow)
        #expect(pay.recurrence.rule == .weekly)
        #expect(pay.recurrence.anchor.weekday == .wednesday)

        let saving = try #require(byName["Transfer to Holiday"])
        #expect(saving.counterpartyUpAccountID == "acc-holiday")
        #expect(saving.patterns.isEmpty)

        #expect(byName["Old Sub"] == nil)        // stopped in March
        #expect(byName["Fresh Grocer"] == nil)   // irregular
    }

    @Test func skipsWhatsAlreadyPlannedOrDismissed() {
        var document = self.document
        document.items.append(BudgetItem(name: "Streaming", segments: [], match: MatchRule(patterns: ["streamflix"])))
        document.reconciliation.dismissedSuggestionKeys = ["out:gym club"]
        let names = RecurringDetector.suggestions(bank: bank, document: document, today: today, timeZone: zone).map(\.name)
        #expect(!names.contains("Streamflix.com 4417"))
        #expect(!names.contains("Gym Club"))
        #expect(names.contains("Salary Example Pty"))
    }

    @Test func addedSuggestionMatchesItsHistory() throws {
        let stream = try #require(RecurringDetector.suggestions(bank: bank, document: document, today: today, timeZone: zone).first { $0.name.hasPrefix("Streamflix") })
        var document = self.document
        document.items.append(RecurringDetector.makeItem(stream, document: document))
        let projection = ProjectionEngine.run(document: document, today: today, horizon: DateSpan(d(2026, 6, 1), d(2026, 12, 31)), bank: {
            var cache = bank
            cache.lastSync = zone.startOfDay(today).addingTimeInterval(9 * 3600)
            cache.coverageStart = zone.startOfDay(d(2025, 9, 1))
            return cache
        }())
        let flows = projection.flows.filter { $0.key.sourceID == document.items.last!.id }
        #expect(flows.filter { $0.date < today }.allSatisfy { $0.status == .matched })
        #expect(flows.first { $0.date == d(2026, 8, 15) }?.reconciliation?.actualDate == d(2026, 8, 17)) // weekend shift matched
    }

    @Test func envelopeSuggestionsAverageAWeek() throws {
        let suggestions = RecurringDetector.envelopeSuggestions(bank: bank, document: document, today: today, timeZone: zone)
        let groceries = try #require(suggestions.first { $0.categoryID == "groceries" })
        #expect(groceries.parentName == "Home")
        #expect(groceries.weeklyAverage.isPositive)
        let envelope = RecurringDetector.makeEnvelope(groceries, document: document, today: today)
        #expect(envelope.isEnvelope)
        #expect(envelope.segments[0].amount.cents % 500 == 0)
        #expect(envelope.segments[0].amount >= groceries.weeklyAverage)
    }
}
