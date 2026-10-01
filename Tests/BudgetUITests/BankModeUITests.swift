import BudgetCore
import Foundation
import SwiftUI
import Testing
@testable import BudgetUI

@MainActor
@Suite struct BankModeUITests {
    private func model() -> AppModel {
        let today = LocalDate(pickerDate: Date())
        var document = SampleData.demo(today: today)
        document.accounts[0].upAccountID = "acc-bills"
        document.accounts[1].upAccountID = "acc-spending"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("budget-ui-\(UUID().uuidString)")
        let model = AppModel(store: DocumentStore(directory: directory), document: document, tokenStore: .memory())
        let zone = document.settings.timeZone
        let noon = zone.startOfDay(today).addingTimeInterval(12 * 3600)
        let bank = BankCache(
            accounts: [
                BankAccount(id: "acc-bills", name: "Bills", accountType: "SAVER", ownershipType: "INDIVIDUAL", balance: .dollars(900)),
                BankAccount(id: "acc-spending", name: "Spending", accountType: "TRANSACTIONAL", ownershipType: "INDIVIDUAL", balance: .dollars(2300)),
            ],
            transactions: [
                BankTransaction(id: "t1", accountID: "acc-spending", status: .settled, createdAt: noon.addingTimeInterval(-86_400 * 2),
                                description: "Corner Grocer", amount: Money(cents: -6_450), categoryID: "groceries"),
                BankTransaction(id: "t2", accountID: "acc-spending", status: .held, createdAt: noon.addingTimeInterval(-3600),
                                description: "Cafe", amount: Money(cents: -550)),
            ],
            categories: [BankCategory(id: "groceries", name: "Groceries")],
            coverageStart: noon.addingTimeInterval(-86_400 * 400),
            lastSync: noon
        )
        model.setBank(bank)
        return model
    }

    @Test func bankModeProjectsAndRenders() {
        let model = model()
        #expect(model.projection.mode == .bank)
        #expect(model.projection.bankBalance == .dollars(3200))
        #expect(model.upBalance == .dollars(3200))
        #expect(model.grid.row(UnplannedRow.spending) != nil)
        for view in [AnyView(CashFlowView()), AnyView(TransactionsView())] {
            let renderer = ImageRenderer(content: view.environment(model).frame(width: 1300, height: 850))
            #expect(renderer.cgImage != nil)
        }
        #expect(model.diagnostics().contains("Transactions: 2"))
        #expect(!model.diagnostics().contains("Cafe"))
    }

    @Test func reconciliationEditsAreUndoable() throws {
        let model = model()
        let undo = UndoManager()
        let flow = try #require(model.projection.flows.first { $0.state == .planned && $0.kind == .item })
        model.setMarkedPaid(true, key: flow.key, undoManager: undo)
        #expect(model.document.reconciliation.markedPaid == [flow.key])
        undo.undo()
        #expect(model.document.reconciliation.markedPaid.isEmpty)
        model.link(["t2"], to: flow.key, undoManager: undo)
        #expect(model.projection.flow(flow.key)?.status == .matched)
        model.unlink(flow.key, undoManager: undo)
        #expect(model.document.reconciliation.manualLinks.isEmpty)
    }

    @Test func oneOffFromATransaction() throws {
        let model = model()
        let dated = try #require(model.projection.unplanned.first { $0.transaction.id == "t2" })
        model.addOneOff(from: dated, undoManager: nil)
        #expect(model.document.items.contains { $0.name == "Cafe" && $0.isOneOff })
        #expect(model.projection.assignments["t2"] != nil)
        let draft = ItemDraft(from: dated, accountID: nil)
        #expect(draft.amount == Money(cents: 550))
        #expect(draft.patterns == "cafe")
    }

    @Test func accountNamesLoseLeadingEmoji() {
        #expect(AppModel.cleanName("🏠 Essentials") == "Essentials")
        #expect(AppModel.cleanName("Spending") == "Spending")
    }
}
