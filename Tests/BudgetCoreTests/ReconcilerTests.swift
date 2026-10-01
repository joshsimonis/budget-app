import Foundation
import Testing
@testable import BudgetCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }
private func money(_ text: String) -> Money { Money(parsing: text)! }
private func at(_ text: String) -> Date { RFC3339.parse(text)! }

private func txn(_ id: String, _ amount: String, _ created: String, account: String = "acc-s", description: String,
                 status: TransactionStatus = .settled, category: String? = nil, transferTo: String? = nil) -> BankTransaction {
    BankTransaction(id: id, accountID: account, status: status, createdAt: at(created), description: description,
                    amount: money(amount), categoryID: category, transferAccountID: transferTo)
}

/// Wednesday 14 Oct 2026 with Up connected. See the expected values worked out in each test.
fileprivate struct BankScenario {
    let spending = Account(id: SampleData.fixtureID(1), name: "Spending", upAccountID: "acc-s", sortIndex: 0)
    let bills = Account(id: SampleData.fixtureID(2), name: "Bills", upAccountID: "acc-b", sortIndex: 1)
    let holiday = Account(id: SampleData.fixtureID(3), name: "Holiday", upAccountID: "acc-h", includedInTotal: false, sortIndex: 2)

    func item(_ n: Int, _ name: String, _ amount: String, _ rule: RecurrenceRule, anchor: LocalDate, start: LocalDate,
              account: Account, match: [String]? = nil, envelope: EnvelopeRule? = nil) -> BudgetItem {
        BudgetItem(id: SampleData.fixtureID(n), name: name, accountID: account.id, envelope: envelope,
                   segments: [ScheduleSegment(start: start, recurrence: Recurrence(rule, anchor: anchor), amount: money(amount))],
                   match: match.map { MatchRule(patterns: $0) }, sortIndex: n)
    }

    var document: BudgetDocument {
        BudgetDocument(accounts: [spending, bills, holiday], items: [
            item(10, "Rent", "500", .weekly, anchor: d(2026, 10, 12), start: d(2026, 10, 12), account: bills, match: ["rent"]),
            item(11, "Credit card", "200", .fortnightly, anchor: d(2026, 10, 15), start: d(2026, 10, 12), account: spending, match: ["card"]),
            item(12, "Phone", "45", .monthly, anchor: d(2026, 7, 11), start: d(2026, 10, 1), account: bills, match: ["telco"]),
            item(13, "Gym", "30", .monthly, anchor: d(2026, 7, 4), start: d(2026, 10, 1), account: spending, match: ["gym"]),
            item(14, "Streaming", "15", .monthly, anchor: d(2026, 7, 20), start: d(2026, 9, 1), account: spending),
            item(15, "Food", "300", .weekly, anchor: d(2026, 10, 12), start: d(2026, 10, 12), account: spending,
                 envelope: EnvelopeRule(categoryIDs: ["groceries"])),
        ])
    }

    var transactions: [BankTransaction] {
        [
            txn("rent", "-500", "2026-10-12T08:00:00+11:00", account: "acc-b", description: "Rent Payment"),
            txn("groc1", "-120", "2026-10-12T17:30:00+11:00", description: "Grocer", category: "groceries"),
            txn("holiday", "-250", "2026-10-12T09:00:00+11:00", description: "Transfer to Holiday", transferTo: "acc-h"),
            txn("card", "-200", "2026-10-13T10:00:00+11:00", description: "Card Repayment"),
            txn("groc2", "-60", "2026-10-13T18:00:00+11:00", description: "Grocer", category: "groceries"),
            txn("refund", "20", "2026-10-13T19:00:00+11:00", description: "Grocer refund", category: "groceries"),
            txn("move-out", "-100", "2026-10-13T12:00:00+11:00", description: "Transfer to Bills", transferTo: "acc-b"),
            txn("move-in", "100", "2026-10-13T12:00:00+11:00", account: "acc-b", description: "Transfer from Spending", transferTo: "acc-s"),
            txn("cafe", "-8.50", "2026-10-14T08:15:00+11:00", description: "Cafe", status: .held),
        ]
    }

    func bank(_ transactions: [BankTransaction]? = nil) -> BankCache {
        BankCache(
            accounts: [
                BankAccount(id: "acc-s", name: "Spending", accountType: "TRANSACTIONAL", ownershipType: "INDIVIDUAL", balance: money("1000")),
                BankAccount(id: "acc-b", name: "Bills", accountType: "SAVER", ownershipType: "INDIVIDUAL", balance: money("500")),
                BankAccount(id: "acc-h", name: "Holiday", accountType: "SAVER", ownershipType: "INDIVIDUAL", balance: money("3000")),
            ],
            transactions: (transactions ?? self.transactions).sorted { $0.createdAt < $1.createdAt },
            categories: [BankCategory(id: "groceries", name: "Groceries", parentID: "home"), BankCategory(id: "home", name: "Home")],
            coverageStart: at("2025-09-14T00:00:00+10:00"),
            lastSync: at("2026-10-14T09:00:00+11:00")
        )
    }

    func run(_ document: BudgetDocument? = nil, bank: BankCache? = nil) -> Projection {
        ProjectionEngine.run(document: document ?? self.document, today: d(2026, 10, 14), bank: bank ?? self.bank())
    }

    func status(_ projection: Projection, _ n: Int, _ date: LocalDate) -> OccurrenceStatus? {
        projection.flows.first { $0.key.sourceID == SampleData.fixtureID(n) && $0.key.originalDate == date }?.status
    }
}

@Suite struct BankProjectionTests {
    private let scenario = BankScenario()

    @Test func anchorsOnTheBankBalanceAndProjectsTheRestOfTheWeek() throws {
        let p = scenario.run()
        #expect(p.mode == .bank)
        #expect(p.bankBalance == money("1500")) // the Holiday saver isn't counted
        // Today: 1,500 − phone 45 (pending) − envelope 28 (140 left over 5 days) = 1,427.
        #expect(p.ledger(on: d(2026, 10, 14))?.closing == money("1427"))
        // Thursday's card payment was paid early, so only the envelope comes out each day.
        #expect(p.ledger(on: d(2026, 10, 15))?.closing == money("1399"))
        #expect(p.ledger(on: d(2026, 10, 18))?.closing == money("1315"))
        // Past days are rebuilt from transactions (the internal transfer cancels out).
        #expect(p.ledger(on: d(2026, 10, 13))?.closing == money("1508.50"))
        #expect(p.ledger(on: d(2026, 10, 12))?.closing == money("1748.50"))
        #expect(p.ledger(on: d(2026, 10, 11))?.closing == money("2618.50"))
        #expect(p.ledger(on: d(2026, 10, 13))?.isActual == true)
        #expect(p.ledger(on: d(2026, 10, 14))?.isActual == false)
    }

    @Test func statusesReflectWhatHappened() {
        let p = scenario.run()
        #expect(scenario.status(p, 10, d(2026, 10, 12)) == .matched)
        #expect(scenario.status(p, 11, d(2026, 10, 15)) == .matched) // paid early on the 13th
        #expect(p.flows.first { $0.key.sourceID == SampleData.fixtureID(11) && $0.key.originalDate == d(2026, 10, 15) }?.reconciliation?.actualDate == d(2026, 10, 13))
        #expect(scenario.status(p, 12, d(2026, 10, 11)) == .pending)
        #expect(scenario.status(p, 13, d(2026, 10, 4)) == .missed)
        #expect(scenario.status(p, 14, d(2026, 9, 20)) == .assumed)  // no matching set up
        #expect(scenario.status(p, 14, d(2026, 10, 20)) == nil)       // still to come
        #expect(scenario.status(p, 10, d(2026, 10, 19)) == .upcoming)
        let food = p.envelopes.first { $0.span.contains(d(2026, 10, 14)) }
        #expect(food?.spend?.spent == money("160")) // 120 + 60 − 20 refund
        #expect(food?.remaining == money("140"))
        #expect(food?.allocations.map(\.date) == [d(2026, 10, 14), d(2026, 10, 15), d(2026, 10, 16), d(2026, 10, 17), d(2026, 10, 18)])
        #expect(Set(p.unplanned.map(\.transaction.id)) == ["holiday", "cafe"])
    }

    @Test func weekColumnAddsUpActualsAndPlan() throws {
        let p = scenario.run()
        let grid = GridBuilder.build(p, document: scenario.document, granularity: .week)
        let week = try #require(grid.bucketIndex(containing: d(2026, 10, 14)))
        #expect(grid.summary.opening[week] == money("2618.50"))
        #expect(grid.summary.totalOut[week] == money("1323.50"))
        #expect(grid.summary.totalIn[week] == money("20"))
        #expect(grid.summary.closing[week] == money("1315"))

        let rent = try #require(grid.row("item:\(SampleData.fixtureID(10).uuidString)"))
        #expect(rent.cells[week].status == .matched)
        #expect(rent.cells[week].amount == money("500"))
        let phone = try #require(grid.row("item:\(SampleData.fixtureID(12).uuidString)"))
        #expect(phone.cells[week].status == .pending)
        let gym = try #require(grid.row("item:\(SampleData.fixtureID(13).uuidString)"))
        let gymWeek = try #require(grid.bucketIndex(containing: d(2026, 10, 4)))
        #expect(gym.cells[gymWeek].status == .missed)
        let food = try #require(grid.row("item:\(SampleData.fixtureID(15).uuidString)"))
        #expect(food.cells[week].amount == money("300"))
        #expect(food.cells[week].envelopeSpent == money("160"))
        let other = try #require(grid.row(UnplannedRow.spending))
        #expect(other.cells[week].amount == money("258.50"))
        #expect(grid.row(UnplannedRow.income) == nil)
    }

    @Test func resultsDontDependOnTransactionOrder() {
        let shuffled = scenario.bank(scenario.transactions.reversed())
        let a = scenario.run()
        let b = scenario.run(bank: shuffled)
        #expect(a.days == b.days)
        #expect(a.flows.map(\.reconciliation) == b.flows.map(\.reconciliation))
    }

    @Test func markedPaidAndManualLinks() {
        var document = scenario.document
        let phone = OccurrenceKey(sourceID: SampleData.fixtureID(12), originalDate: d(2026, 10, 11))
        let gym = OccurrenceKey(sourceID: SampleData.fixtureID(13), originalDate: d(2026, 10, 4))
        document.reconciliation.markedPaid = [phone]
        document.reconciliation.manualLinks = [ManualLink(occurrence: gym, transactionIDs: ["cafe"])]
        let p = scenario.run(document)
        #expect(scenario.status(p, 12, d(2026, 10, 11)) == .markedPaid)
        #expect(scenario.status(p, 13, d(2026, 10, 4)) == .matched)
        // The phone no longer comes out today.
        #expect(p.ledger(on: d(2026, 10, 14))?.closing == money("1472"))
        #expect(!p.unplanned.contains { $0.transaction.id == "cafe" })
    }

    @Test func excludedAccountsDontCount() {
        var document = scenario.document
        document.accounts[1].includedInTotal = false // Bills no longer counted
        let p = scenario.run(document)
        #expect(p.bankBalance == money("1000"))
        // The rent came from Bills, so it's no longer matched in the counted accounts.
        #expect(scenario.status(p, 10, d(2026, 10, 12)) == .pending)
    }
}

@Suite struct ReconcilerRuleTests {
    private func reconcile(items: [BudgetItem], transactions: [BankTransaction], state: ReconciliationState = ReconciliationState()) -> ReconciliationResult {
        var document = BudgetDocument(items: items)
        document.reconciliation = state
        let today = d(2026, 10, 30)
        let context = PlanContext(document: document, today: today, horizon: DateSpan(d(2026, 9, 1), d(2026, 11, 30)))
        let flows = items.flatMap { OccurrenceGenerator.flows(for: $0, context: context) }
        let zone = TimeZoneBridge()
        return Reconciler.reconcile(
            flows: flows, envelopes: [],
            transactions: transactions.map { DatedTransaction(transaction: $0, date: zone.localDate(for: $0.createdAt)) },
            document: document, bank: BankCache(),
            options: ReconcileOptions(today: today, graceDays: 4, coverageStart: nil, anchorDate: today)
        )
    }

    private func weekly(_ name: String, _ amount: String, match: [String], tolerance: Int? = nil) -> BudgetItem {
        BudgetItem(name: name, segments: [ScheduleSegment(start: d(2026, 10, 5), end: d(2026, 10, 18), recurrence: Recurrence(.weekly, anchor: d(2026, 10, 5)), amount: money(amount))],
                   match: MatchRule(patterns: match, toleranceBasisPoints: tolerance))
    }

    @Test func eachOccurrenceGetsItsNearestTransaction() {
        let item = weekly("Club", "10", match: ["club"])
        let result = reconcile(items: [item], transactions: [
            txn("a", "-10", "2026-10-05T10:00:00+11:00", description: "Club"),
            txn("b", "-10", "2026-10-07T10:00:00+11:00", description: "Club"),
            txn("c", "-10", "2026-10-12T10:00:00+11:00", description: "Club"),
        ])
        #expect(result.flows[OccurrenceKey(sourceID: item.id, originalDate: d(2026, 10, 5))]?.transactionIDs == ["a"])
        #expect(result.flows[OccurrenceKey(sourceID: item.id, originalDate: d(2026, 10, 12))]?.transactionIDs == ["c"])
        #expect(result.unplanned.map(\.transaction.id) == ["b"])
    }

    @Test func amountsDecideBetweenTwoBillsFromOneMerchant() {
        let music = weekly("Music", "16", match: ["apple"])
        let storage = weekly("Storage", "28", match: ["apple"])
        let result = reconcile(items: [music, storage], transactions: [
            txn("x", "-28", "2026-10-05T10:00:00+11:00", description: "Apple"),
            txn("y", "-16", "2026-10-05T11:00:00+11:00", description: "Apple"),
            txn("big", "-2000", "2026-10-12T11:00:00+11:00", description: "Apple Store"),
        ])
        #expect(result.flows[OccurrenceKey(sourceID: music.id, originalDate: d(2026, 10, 5))]?.transactionIDs == ["y"])
        #expect(result.flows[OccurrenceKey(sourceID: storage.id, originalDate: d(2026, 10, 5))]?.transactionIDs == ["x"])
        // A big one-off purchase isn't mistaken for a subscription.
        #expect(result.flows[OccurrenceKey(sourceID: storage.id, originalDate: d(2026, 10, 12))]?.status == .missed)
    }

    @Test func toleranceAndIgnoredTransactions() {
        let strict = weekly("Insurance", "100", match: ["insure"], tolerance: 200) // ±2% (+$1)
        let result = reconcile(items: [strict], transactions: [
            txn("off", "-110", "2026-10-05T10:00:00+11:00", description: "Insure Co"),
            txn("ok", "-102.50", "2026-10-12T10:00:00+11:00", description: "Insure Co"),
        ])
        #expect(result.flows[OccurrenceKey(sourceID: strict.id, originalDate: d(2026, 10, 5))]?.status == .missed)
        #expect(result.flows[OccurrenceKey(sourceID: strict.id, originalDate: d(2026, 10, 12))]?.transactionIDs == ["ok"])

        let item = weekly("Club", "10", match: ["club"])
        let ignored = reconcile(items: [item], transactions: [txn("a", "-10", "2026-10-05T10:00:00+11:00", description: "Club")],
                                state: ReconciliationState(ignoredTransactionIDs: ["a"]))
        #expect(ignored.flows[OccurrenceKey(sourceID: item.id, originalDate: d(2026, 10, 5))]?.status == .missed)
        #expect(ignored.unplanned.map(\.transaction.id) == ["a"])
    }

    @Test func transfersOnlyMatchACounterpartyRule() {
        var tax = weekly("Tax saver", "300", match: [])
        tax.match = MatchRule(patterns: [], counterpartyUpAccountID: "acc-tax")
        let result = reconcile(items: [tax], transactions: [
            txn("t", "-300", "2026-10-05T10:00:00+11:00", description: "Transfer to Tax", transferTo: "acc-tax"),
            txn("u", "-300", "2026-10-12T10:00:00+11:00", description: "Transfer to Holiday", transferTo: "acc-holiday"),
        ])
        #expect(result.flows[OccurrenceKey(sourceID: tax.id, originalDate: d(2026, 10, 5))]?.transactionIDs == ["t"])
        #expect(result.flows[OccurrenceKey(sourceID: tax.id, originalDate: d(2026, 10, 12))]?.status == .missed)
    }
}

@Suite struct ProjectionPerformanceTests {
    @Test func largeHistoryStaysFast() {
        let today = d(2026, 10, 1)
        var document = SampleData.demo(today: today)
        // Forty more bills with matching text.
        for n in 0..<40 {
            document.items.append(BudgetItem(
                name: "Bill \(n)",
                accountID: document.accounts[0].id,
                segments: [ScheduleSegment(start: d(2025, 1, 1), recurrence: Recurrence(n % 2 == 0 ? .monthly : .weekly, anchor: d(2025, 1, 1 + n % 28)),
                                           amount: Money(cents: Int64(1000 + n * 37)))],
                match: MatchRule(patterns: ["bill \(n)"])
            ))
        }
        var bank = SampleData.demoBank(for: &document, today: today)
        // About 4,000 extra transactions over 13 months.
        let zone = TimeZoneBridge()
        var extra: [BankTransaction] = []
        var day = today.adding(months: -13)
        var n = 0
        while day < today {
            for k in 0..<10 {
                extra.append(BankTransaction(id: "x\(n)", accountID: "demo-spending", status: .settled,
                                             createdAt: zone.startOfDay(day).addingTimeInterval(Double(3600 * (8 + k))),
                                             description: "Shop \(k)", amount: Money(cents: -Int64(500 + k * 120)), categoryID: k % 3 == 0 ? "groceries" : nil))
                n += 1
            }
            day = day.adding(days: 1)
        }
        bank.transactions = (bank.transactions + extra).sorted { $0.createdAt < $1.createdAt }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let projection = ProjectionEngine.run(document: document, today: today, bank: bank)
            _ = GridBuilder.build(projection, document: document, granularity: .day)
            _ = RecurringDetector.suggestions(bank: bank, document: document, today: today, timeZone: zone)
        }
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }
}
