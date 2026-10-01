import BudgetCore
import Foundation
import SwiftUI
import Testing
@testable import BudgetUI

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }

@MainActor
@Suite struct DraftTests {
    @Test func newMonthlyBill() {
        var draft = ItemDraft(newKind: .bill, today: d(2026, 10, 1))
        draft.name = " Phone "
        draft.amount = .dollars(55)
        draft.anchor = d(2026, 10, 15)
        draft.patterns = "telstra, mobile"
        let item = draft.build(historyStart: d(2026, 8, 3))
        #expect(item.name == "Phone")
        #expect(item.flow == .outflow)
        #expect(item.segments.count == 1)
        #expect(item.segments[0].start == d(2026, 8, 3))
        #expect(item.segments[0].recurrence == Recurrence(.monthly, anchor: d(2026, 10, 15)))
        #expect(item.match?.patterns == ["telstra", "mobile"])
    }

    @Test func newEnvelopeAndOneOff() {
        var envelope = ItemDraft(newKind: .envelope, today: d(2026, 10, 1))
        envelope.name = "Groceries"
        envelope.amount = .dollars(180)
        envelope.categories = "groceries, takeaway"
        let item = envelope.build(historyStart: d(2026, 8, 3))
        #expect(item.isEnvelope)
        #expect(item.envelope?.categoryIDs == ["groceries", "takeaway"])
        #expect(item.segments[0].recurrence.rule == .weekly)
        #expect(item.segments[0].recurrence.anchor == d(2026, 9, 28))

        var sale = ItemDraft(newKind: .oneOff, today: d(2026, 10, 1))
        sale.name = "Sold bike"
        sale.amount = .dollars(300)
        sale.oneOffInflow = true
        sale.anchor = d(2026, 10, 20)
        let oneOff = sale.build(historyStart: d(2026, 8, 3))
        #expect(oneOff.isOneOff)
        #expect(oneOff.flow == .inflow)
        #expect(oneOff.segments[0].recurrence.anchor == d(2026, 10, 20))
    }

    @Test func editingKeepsHistoryAndPhase() {
        let original = BudgetItem(
            name: "Card",
            segments: [ScheduleSegment(start: d(2026, 7, 1), recurrence: Recurrence(.fortnightly, anchor: d(2026, 7, 2)), amount: .dollars(200))]
        )
        var draft = ItemDraft(item: original, today: d(2026, 10, 1))
        #expect(draft.anchor == d(2026, 10, 8))
        draft.addChange(from: d(2026, 12, 1), amount: .dollars(250))
        let item = draft.build(historyStart: d(2026, 8, 3))
        #expect(item.segments.map(\.amount) == [.dollars(200), .dollars(250)])
        #expect(item.segments[1].recurrence.anchor == d(2026, 7, 2)) // phase kept
        #expect(item.segments[0].start == d(2026, 7, 1))
    }

    @Test func newIncomeDraftBuildsASource() {
        var draft = IncomeDraft(newKind: .dayRate, today: d(2026, 10, 1), accountID: nil)
        draft.source.name = "Contract"
        draft.rateAmount = .dollars(750)
        draft.nextPay = d(2026, 10, 7)
        let source = draft.build()
        #expect(source.kind == .dayRate)
        #expect(source.rates.count == 1)
        #expect(source.rates[0].amount == .dollars(750))
        #expect(source.rates[0].unit == .daily)
        #expect(source.paySchedule.rule == .weekly)
        #expect(source.paySchedule.anchor == d(2026, 10, 7))
        #expect(source.periodEndOffsetDays == 3)

        var rise = IncomeDraft(source: source, today: d(2026, 10, 1))
        rise.addRate(from: d(2027, 1, 1), amount: .dollars(800))
        let raised = rise.build()
        #expect(raised.rates.map(\.amount) == [.dollars(750), .dollars(800)])
        let quote = rise.quote(applyStandardDeduction: true, year: FinancialYear(startYear: 2026))
        #expect(quote.rows[0].breakdown.gross == .dollars(3750))
    }

    @Test func screensRender() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("budget-ui-\(UUID().uuidString)")
        let model = AppModel(store: DocumentStore(directory: directory), document: SampleData.demo(today: d(2026, 10, 1)))
        let views: [AnyView] = [
            AnyView(ItemsListView()),
            AnyView(IncomeListView()),
            AnyView(PeriodsListView()),
            AnyView(PayCalculatorView()),
            AnyView(SettingsView()),
            AnyView(ItemEditorSheet(draft: ItemDraft(item: model.document.items[0], today: model.today))),
            AnyView(IncomeEditorSheet(draft: IncomeDraft(source: model.document.incomes[0], today: model.today))),
            AnyView(PeriodEditorSheet(period: model.document.periods[0], isNew: false)),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.environment(model).frame(width: 1000, height: 800))
            #expect(renderer.cgImage != nil)
        }
    }
}
