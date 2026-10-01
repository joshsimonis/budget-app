import Testing
@testable import BudgetCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(y, m, day) }
private func money(_ text: String) -> Money { Money(parsing: text)! }

/// A synthetic re-creation of a weekly budgeting spreadsheet (plan Appendix C).
@Suite struct SheetScenarioTests {
    let document = SampleData.sheetScenario()
    let horizon = DateSpan(LocalDate(2027, 1, 25), LocalDate(2027, 4, 4))

    var projection: Projection {
        ProjectionEngine.run(document: document, today: d(2027, 2, 3), horizon: horizon)
    }

    @Test func weeklyTotalsMatchTheSheet() throws {
        let grid = GridBuilder.build(projection, document: document, granularity: .week)
        let expected: [(LocalDate, String, String, String)] = [
            (d(2027, 2, 1), "2210.00", "2071.00", "3861.00"),
            (d(2027, 2, 8), "1270.00", "2498.00", "5089.00"),
            (d(2027, 2, 15), "3215.00", "2498.00", "4372.00"),
            (d(2027, 2, 22), "522.99", "0.00", "3849.01"),
            (d(2027, 3, 1), "1430.00", "0.00", "2419.01"),
            (d(2027, 3, 8), "1270.00", "350.00", "1499.01"),
            (d(2027, 3, 15), "1775.00", "2071.00", "1746.00"),
            (d(2027, 3, 22), "1122.99", "2498.00", "3121.01"),
        ]
        for (weekStart, out, incoming, running) in expected {
            let index = try #require(grid.bucketIndex(containing: weekStart))
            #expect(grid.buckets[index].span.start == weekStart)
            #expect(grid.summary.totalOut[index] == money(out), "out, week of \(weekStart)")
            #expect(grid.summary.totalIn[index] == money(incoming), "in, week of \(weekStart)")
            #expect(grid.summary.closing[index] == money(running), "running, week of \(weekStart)")
        }
        // Before the first checkpoint the running total is unknown (blank, like the sheet).
        #expect(grid.summary.closing[0] == nil)
        // The checkpoint on 15 Mar resets the running total.
        let reset = try #require(grid.bucketIndex(containing: d(2027, 3, 15)))
        #expect(grid.summary.checkpoint[reset] == money("1450"))
        #expect(grid.summary.opening[reset] == money("1450"))
    }

    @Test func februaryMonthEqualsItsFourWeeks() throws {
        let grid = GridBuilder.build(projection, document: document, granularity: .month)
        let feb = try #require(grid.bucketIndex(containing: d(2027, 2, 14)))
        #expect(grid.summary.totalOut[feb] == money("7217.99"))
        #expect(grid.summary.totalIn[feb] == money("7067.00"))
        #expect(grid.summary.closing[feb] == money("3849.01"))
    }

    @Test func unpaidWeeksLagTravelByOneWeekBecausePayIsInArrears() {
        let pays = projection.payEvents.filter { $0.sourceID == SampleData.fixtureID(30) }
        let byDate = Dictionary(uniqueKeysWithValues: pays.map { ($0.payDate, $0) })
        // Travel is 15 Feb – 7 Mar; pays on 24 Feb, 3 Mar and 10 Mar cover those weeks.
        for date in [d(2027, 2, 24), d(2027, 3, 3), d(2027, 3, 10)] {
            #expect(byDate[date]?.state == .unpaid, "pay on \(date)")
            #expect(byDate[date]?.received == .zero)
            #expect(byDate[date]?.incomeLost == money("2498"))
        }
        #expect(byDate[d(2027, 2, 17)]?.received == money("2498"))
        #expect(byDate[d(2027, 2, 17)]?.workPeriod == DateSpan(d(2027, 2, 8), d(2027, 2, 14)))
        // Australia Day (26 Jan) and Labour Day (8 Mar) each cost a day.
        #expect(byDate[d(2027, 2, 3)]?.daysWorkedHundredths == 400)
        #expect(byDate[d(2027, 2, 3)]?.breakdown.withholding == money("729"))
        #expect(byDate[d(2027, 3, 17)]?.received == money("2071"))
    }

    @Test func gridRowsLookLikeTheSheet() throws {
        let grid = GridBuilder.build(projection, document: document, granularity: .week)
        #expect(grid.sections.map(\.title) == ["Travel", "Essentials", "Spending", "One-offs", "Income"])
        #expect(grid.bands.map(\.name) == ["Travel"])
        let feb15 = try #require(grid.bucketIndex(containing: d(2027, 2, 15)))
        let mar1 = try #require(grid.bucketIndex(containing: d(2027, 3, 1)))
        #expect(grid.bands[0].firstBucket == feb15)
        #expect(grid.bands[0].lastBucket == mar1)

        let rent = try #require(grid.row("item:\(SampleData.fixtureID(10).uuidString)"))
        #expect(rent.cells[feb15].status == .paused)
        #expect(rent.cells[feb15].amount == nil)
        let food = try #require(grid.row("item:\(SampleData.fixtureID(11).uuidString)"))
        let feb8 = try #require(grid.bucketIndex(containing: d(2027, 2, 8)))
        #expect(food.kind == .envelope)
        #expect(food.cells[feb8].amount == money("300"))
        #expect(food.cells[feb15].status == .paused)
        let family = try #require(grid.row("item:\(SampleData.fixtureID(19).uuidString)"))
        #expect(family.cells[mar1].amount == money("780"))
        let contract = try #require(grid.row("income:\(SampleData.fixtureID(30).uuidString)"))
        #expect(contract.cells[feb8].amount == money("2498"))
        let feb22 = try #require(grid.bucketIndex(containing: d(2027, 2, 22)))
        #expect(contract.cells[feb22].status == .unpaid)
    }

    @Test func dayWeekAndMonthTotalsAgree() {
        let p = projection
        let days = GridBuilder.build(p, document: document, granularity: .day)
        let weeks = GridBuilder.build(p, document: document, granularity: .week)
        let months = GridBuilder.build(p, document: document, granularity: .month)
        func total(_ grid: CashFlowGrid) -> (Money, Money) {
            (grid.summary.totalOut.reduce(.zero, +), grid.summary.totalIn.reduce(.zero, +))
        }
        #expect(total(days) == total(weeks))
        #expect(total(weeks) == total(months))
        #expect(days.summary.closing.last! == months.summary.closing.last!)
        // Each row's cells also add up across granularities.
        for section in weeks.sections {
            for row in section.rows {
                let weekly = row.cells.compactMap(\.amount).reduce(.zero, +)
                let daily = days.row(row.id)!.cells.compactMap(\.amount).reduce(.zero, +)
                #expect(weekly == daily, "\(row.title)")
            }
        }
    }
}
