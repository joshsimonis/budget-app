import Foundation
import Testing
@testable import BudgetCore

private func at(_ text: String) -> Date { RFC3339.parse(text)! }

private func txn(_ id: String, _ cents: Int64, _ created: String, status: TransactionStatus = .settled, description: String = "Shop", account: String = "a") -> BankTransaction {
    BankTransaction(id: id, accountID: account, status: status, createdAt: at(created), description: description, amount: Money(cents: cents))
}

@Suite struct BankMergeTests {
    @Test func heldBecomesSettledWithSameID() {
        var cache = BankCache(transactions: [txn("x", -1000, "2026-09-29T10:00:00+10:00", status: .held)])
        let report = TransactionMerge.apply(fetched: [txn("x", -1050, "2026-09-29T10:00:00+10:00")], windowStart: at("2026-09-20T00:00:00+10:00"), complete: true, to: &cache)
        #expect(report.updated == 1)
        #expect(cache.transactions.first?.status == .settled)
        #expect(cache.transactions.first?.amount == Money(cents: -1050))
    }

    @Test func incompleteFetchNeverDeletes() {
        var cache = BankCache(transactions: [txn("x", -1000, "2026-09-29T10:00:00+10:00")])
        TransactionMerge.apply(fetched: [], windowStart: at("2026-09-20T00:00:00+10:00"), complete: false, to: &cache)
        #expect(cache.transactions.count == 1)
        let report = TransactionMerge.apply(fetched: [], windowStart: at("2026-09-20T00:00:00+10:00"), complete: true, to: &cache)
        #expect(cache.transactions.isEmpty)
        #expect(report.removed.map(\.id) == ["x"])
    }

    @Test func linkRepairFollowsAReplacedTransaction() {
        let old = txn("old", -4500, "2026-09-29T10:00:00+10:00", description: "Phone Co")
        let replacement = txn("new", -4550, "2026-09-30T10:00:00+10:00", description: "phone  co")
        let cache = BankCache(transactions: [replacement])
        let key = OccurrenceKey(sourceID: UUID(), originalDate: LocalDate(2026, 9, 29))
        var state = ReconciliationState(manualLinks: [ManualLink(occurrence: key, transactionIDs: ["old"])], ignoredTransactionIDs: ["old"])
        let notes = LinkRepair.repair(&state, removed: [old], cache: cache)
        #expect(notes.isEmpty)
        #expect(state.manualLinks.first?.transactionIDs == ["new"])
        #expect(state.ignoredTransactionIDs.isEmpty)

        var unrepairable = ReconciliationState(manualLinks: [ManualLink(occurrence: key, transactionIDs: ["old"])])
        let dropped = LinkRepair.repair(&unrepairable, removed: [old], cache: BankCache())
        #expect(dropped.count == 1)
        #expect(unrepairable.manualLinks.isEmpty)
    }

    @Test func categoriesExpandToChildren() {
        let cache = BankCache(categories: [BankCategory(id: "home", name: "Home"), BankCategory(id: "groceries", name: "Groceries", parentID: "home")])
        #expect(cache.expandCategories(["home"]) == ["home", "groceries"])
        #expect(cache.expandCategories(["groceries"]) == ["groceries"])
    }

    @Test func cacheRoundTrips() throws {
        let cache = BankCache(accounts: [BankAccount(id: "a", name: "Spending", accountType: "TRANSACTIONAL", ownershipType: "INDIVIDUAL", balance: Money(cents: 100))],
                              transactions: [txn("x", -1000, "2026-09-29T10:00:00+10:00")], lastSync: at("2026-10-01T00:00:00Z"))
        #expect(try BankCache.decode(BankCache.encode(cache)) == cache)
    }

    @Test func textMatching() {
        let t = BankTransaction(id: "1", accountID: "a", status: .settled, createdAt: Date(), description: "Telstra Mobile", rawText: "TELSTRA  PAYMENT 123", amount: Money(cents: -100))
        #expect(TextMatch.matches(["telstra"], t))
        #expect(TextMatch.matches(["payment 123"], t))
        #expect(!TextMatch.matches(["optus", " "], t))
    }
}
