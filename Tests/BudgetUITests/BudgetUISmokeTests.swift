import BudgetCore
import Foundation
import SwiftUI
import Testing
@testable import BudgetUI

@MainActor
@Suite struct BudgetUISmokeTests {
    private func makeModel(_ document: BudgetDocument = SampleData.demo(today: LocalDate(2026, 10, 1))) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("budget-ui-\(UUID().uuidString)")
        return AppModel(store: DocumentStore(directory: directory), document: document)
    }

    @Test func rendersCashFlow() {
        let model = makeModel()
        let renderer = ImageRenderer(content: CashFlowView().environment(model).frame(width: 1400, height: 900))
        #expect(renderer.cgImage != nil)
        #expect(!model.grid.sections.isEmpty)
    }

    @Test func rendersWelcome() {
        let model = makeModel(BudgetDocument())
        #expect(model.showsWelcome)
        let renderer = ImageRenderer(content: WelcomeView().environment(model).frame(width: 900, height: 700))
        #expect(renderer.cgImage != nil)
    }

    @Test func pagingStaysInBounds() {
        let model = makeModel()
        model.visibleColumns = 10
        model.move(by: -10_000)
        #expect(model.visibleRange(columns: 10).lowerBound == 0)
        model.move(by: 10_000)
        #expect(model.visibleRange(columns: 10).upperBound == model.grid.buckets.count)
        model.goToToday()
        let range = model.visibleRange(columns: 10)
        #expect(range.contains(model.grid.currentBucket ?? -1))
        model.granularity = .month
        #expect(model.grid.granularity == .month)
    }

    @Test func editsAreUndoable() throws {
        let model = makeModel()
        let undo = UndoManager()
        let item = try #require(model.document.items.first)
        let date = try #require(model.projection.flows.first { $0.key.sourceID == item.id }?.key.originalDate)
        model.setOverride(OccurrenceOverride(originalDate: date, skip: true), itemID: item.id, undoManager: undo)
        #expect(model.document.item(item.id)?.override(for: date)?.skip == true)
        undo.undo()
        #expect(model.document.item(item.id)?.override(for: date) == nil)
        undo.redo()
        #expect(model.document.item(item.id)?.override(for: date)?.skip == true)
    }
}
