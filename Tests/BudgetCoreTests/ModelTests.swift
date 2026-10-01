import Foundation
import Testing
@testable import BudgetCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }

private func fortnightlyBill(amount: Int64 = 200) -> BudgetItem {
    BudgetItem(
        name: "Card",
        segments: [ScheduleSegment(start: d(2026, 7, 1), recurrence: Recurrence(.fortnightly, anchor: d(2027, 2, 4)), amount: .dollars(amount))]
    )
}

private func allDates(_ item: BudgetItem, _ span: DateSpan) -> [LocalDate] {
    item.segments.flatMap { $0.originalDates(in: span) }.sorted()
}

@Suite struct ItemEditsTests {
    @Test func changeFromDateKeepsFortnightlyPhase() {
        var item = fortnightlyBill()
        let before = allDates(item, DateSpan(d(2027, 1, 1), d(2027, 6, 30)))
        ItemEdits.changeFrom(d(2027, 3, 18), in: &item, amount: .dollars(250))
        #expect(item.segments.count == 2)
        #expect(item.segments[0].end == d(2027, 3, 17))
        #expect(item.segments[1].start == d(2027, 3, 18))
        #expect(item.segments[1].amount == .dollars(250))
        #expect(allDates(item, DateSpan(d(2027, 1, 1), d(2027, 6, 30))) == before)
        #expect(item.amount(on: d(2027, 3, 4)) == .dollars(200))
        #expect(item.amount(on: d(2027, 3, 18)) == .dollars(250))
    }

    @Test func changeOnSegmentStartEditsInPlace() {
        var item = fortnightlyBill()
        ItemEdits.changeFrom(d(2026, 7, 1), in: &item, amount: .dollars(10))
        #expect(item.segments.count == 1)
        #expect(item.segments[0].amount == .dollars(10))
    }

    @Test func changeWithoutReplaceKeepsLaterChanges() {
        var item = fortnightlyBill()
        ItemEdits.changeFrom(d(2027, 6, 3), in: &item, amount: .dollars(300))
        ItemEdits.changeFrom(d(2027, 3, 18), in: &item, amount: .dollars(250))
        #expect(item.segments.map(\.amount) == [.dollars(200), .dollars(250), .dollars(300)])
        #expect(item.segments[1].end == d(2027, 6, 2))

        var replaced = item
        ItemEdits.changeFrom(d(2027, 3, 18), in: &replaced, amount: .dollars(260), replaceLater: true)
        #expect(replaced.segments.map(\.amount) == [.dollars(200), .dollars(260)])
        #expect(replaced.segments[1].end == nil)
    }

    @Test func changingBackMergesIdenticalSegments() {
        var item = fortnightlyBill()
        ItemEdits.changeFrom(d(2027, 3, 18), in: &item, amount: .dollars(250))
        ItemEdits.changeFrom(d(2027, 3, 18), in: &item, amount: .dollars(200))
        #expect(item.segments.count == 1)
        #expect(item.segments[0].end == nil)
    }

    @Test func newRecurrenceDropsOrphanedOverrides() {
        var item = fortnightlyBill()
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 4, 1), amount: .dollars(5)), in: &item)
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 2, 18), skip: true), in: &item)
        // Switch to monthly on the 15th from 15 Mar.
        let report = ItemEdits.changeFrom(d(2027, 3, 15), in: &item, recurrence: Recurrence(.monthly, anchor: d(2027, 3, 15)))
        #expect(report.removedOverrides.map(\.originalDate) == [d(2027, 4, 1)])
        #expect(item.overrides.map(\.originalDate) == [d(2027, 2, 18)])
        #expect(allDates(item, DateSpan(d(2027, 3, 1), d(2027, 5, 31))) == [d(2027, 3, 4), d(2027, 3, 15), d(2027, 4, 15), d(2027, 5, 15)])
    }

    @Test func stopEndsTheItem() {
        var item = fortnightlyBill()
        ItemEdits.changeFrom(d(2027, 6, 3), in: &item, amount: .dollars(300))
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 6, 17), amount: .dollars(1)), in: &item)
        let report = ItemEdits.stop(&item, from: d(2027, 4, 1))
        #expect(item.segments.count == 1)
        #expect(item.segments[0].end == d(2027, 3, 31))
        #expect(report.removedOverrides.count == 1)
        #expect(allDates(item, DateSpan(d(2027, 3, 1), d(2027, 6, 30))) == [d(2027, 3, 4), d(2027, 3, 18)])
    }

    @Test func emptyOverrideRemovesIt() {
        var item = fortnightlyBill()
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 2, 18), amount: .dollars(5)), in: &item)
        #expect(item.override(for: d(2027, 2, 18))?.amount == .dollars(5))
        ItemEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 2, 18)), in: &item)
        #expect(item.overrides.isEmpty)
    }

    @Test func incomeRateChanges() {
        var job = SampleData.sheetScenario().incomes[0]
        IncomeEdits.setRate(RateSegment(from: d(2027, 4, 1), amount: .dollars(750), unit: .daily), in: &job)
        #expect(job.rate(on: d(2027, 3, 31))?.amount == .dollars(700))
        #expect(job.rate(on: d(2027, 4, 1))?.amount == .dollars(750))
        IncomeEdits.setDaysWorked(450, payDate: d(2027, 2, 10), in: &job)
        #expect(job.daysWorkedOverride(for: d(2027, 2, 10))?.hundredths == 450)
        IncomeEdits.setDaysWorked(nil, payDate: d(2027, 2, 10), in: &job)
        #expect(job.daysWorked.isEmpty)
        IncomeEdits.setOverride(OccurrenceOverride(originalDate: d(2027, 2, 11), skip: true), in: &job) // not a pay day
        #expect(IncomeEdits.removeOrphans(in: &job).count == 1)
    }
}

@Suite struct PersistenceTests {
    @Test func roundTrips() throws {
        let document = SampleData.sheetScenario()
        let decoded = try DocumentCodec.decode(DocumentCodec.encode(document))
        #expect(decoded == document)
        let demo = SampleData.demo(today: d(2026, 10, 1))
        #expect(try DocumentCodec.decode(DocumentCodec.encode(demo)) == demo)
    }

    @Test func goldenVersion1FileStillDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "document-v1", withExtension: "json", subdirectory: "Fixtures"))
        let decoded = try DocumentCodec.decode(Data(contentsOf: url))
        #expect(decoded == SampleData.sheetScenario())
    }

    @Test func refusesFilesFromNewerVersions() {
        let data = Data(#"{"schemaVersion": 99}"#.utf8)
        #expect(throws: DocumentCodecError.newerVersion(99)) { try DocumentCodec.decode(data) }
        #expect(throws: DocumentCodecError.self) { try DocumentCodec.decode(Data("nope".utf8)) }
    }

    @Test func storeSavesAtomicallyAndKeepsHourlyBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("budget-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = DocumentStore(directory: dir)
        store.maxBackups = 3
        #expect(try store.load() == nil)

        var document = SampleData.sheetScenario()
        let t0 = try #require(RFC3339.parse("2026-10-01T09:00:00Z"))
        try store.save(document, now: t0)
        #expect(store.backups().isEmpty) // nothing to back up on the first save
        #expect(try store.load() == document)

        document.items.removeLast()
        try store.save(document, now: t0.addingTimeInterval(60))
        #expect(store.backups().count == 1)
        try store.save(document, now: t0.addingTimeInterval(120)) // within the hour: no new backup
        #expect(store.backups().count == 1)
        for hour in 1...5 {
            try store.save(document, now: t0.addingTimeInterval(Double(hour) * 3700))
        }
        #expect(store.backups().count == 3)
        #expect(try store.load() == document)
        let newest = try #require(store.backups().first)
        #expect(newest.lastPathComponent == "budget-20261001-140820.json")
        #expect(DocumentStore.timestamp(from: newest) == t0.addingTimeInterval(5 * 3700))
    }
}

@Suite struct SampleDataTests {
    @Test func demoIsPositionedAroundToday() {
        let today = d(2026, 10, 1)
        let demo = SampleData.demo(today: today)
        #expect(demo.items.count > 10)
        #expect(demo.checkpoints.first?.date == today)
        #expect(demo.periods.first.map { $0.span.start > today } == true)
        #expect(demo.incomes.first?.paySchedule.anchor.weekday == .thursday)
    }

    @Test func fixtureIDsAreStable() {
        #expect(SampleData.fixtureID(30).uuidString == "00000000-0000-4000-8000-00000000001E")
    }
}

@Suite struct DemoBankTests {
    @Test func demoBankReconciles() {
        let today = LocalDate(2026, 10, 1)
        var document = SampleData.demo(today: today)
        let bank = SampleData.demoBank(for: &document, today: today)
        let projection = ProjectionEngine.run(document: document, today: today, bank: bank)
        #expect(projection.mode == .bank)
        #expect(projection.flows.contains { $0.status == .matched })
        #expect(projection.flows.contains { $0.status == .missed })
        #expect(!projection.unplanned.isEmpty)
        #expect(projection.envelopes.contains { ($0.spend?.spent ?? .zero).isPositive })
        let again = SampleData.demoBank(for: &document, today: today)
        #expect(again == bank) // deterministic
    }
}
