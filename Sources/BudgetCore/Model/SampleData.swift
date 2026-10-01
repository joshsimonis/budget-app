import Foundation

/// Made-up budgets. Everything here is synthetic: this repository is public.
public enum SampleData {
    /// A stable UUID for fixtures, e.g. `UUID.fixture(3)` → 00000000-0000-4000-8000-000000000003.
    public static func fixtureID(_ n: Int) -> UUID {
        let hex = String(n, radix: 16)
        let padded = String(repeating: "0", count: max(0, 12 - hex.count)) + hex
        return UUID(uuidString: "00000000-0000-4000-8000-\(padded)")!
    }

    /// A demo budget positioned around `today`, for exploring the app.
    public static func demo(today: LocalDate) -> BudgetDocument {
        let bills = Account(name: "Bills", sortIndex: 0)
        let spending = Account(name: "Spending", sortIndex: 1)
        let monday = today.startOfWeek
        let nextThursday = today.adding(days: IntMath.floorMod(Weekday.thursday.rawValue - today.weekday.rawValue, 7))
        let startOfYear = LocalDate(today.year, 1, 1)

        func recurring(
            _ name: String, _ dollars: Int64, _ rule: RecurrenceRule, anchor: LocalDate,
            account: Account, flow: Flow = .outflow, envelope: EnvelopeRule? = nil, match: [String] = [], order: Int
        ) -> BudgetItem {
            BudgetItem(
                name: name,
                flow: flow,
                accountID: account.id,
                envelope: envelope,
                segments: [ScheduleSegment(start: startOfYear, recurrence: Recurrence(rule, anchor: anchor), amount: .dollars(dollars))],
                match: match.isEmpty ? nil : MatchRule(patterns: match),
                sortIndex: order
            )
        }

        let groceries = recurring("Groceries", 180, .weekly, anchor: monday, account: spending,
                                  envelope: EnvelopeRule(categoryIDs: ["groceries"]), order: 10)
        let transport = recurring("Public transport", 40, .weekly, anchor: monday, account: spending, match: ["myki", "transport"], order: 12)
        var items = [
            recurring("Rent", 1950, .monthly, anchor: LocalDate(today.year, 1, 1), account: bills, match: ["rent"], order: 0),
            recurring("Electricity", 420, .quarterly, anchor: today.adding(days: 20), account: bills, match: ["energy"], order: 1),
            recurring("Phone", 55, .monthly, anchor: today.adding(days: 9), account: bills, match: ["mobile"], order: 2),
            recurring("Internet", 79, .monthly, anchor: today.adding(days: 3), account: bills, match: ["internet"], order: 3),
            recurring("Health insurance", 160, .monthly, anchor: today.adding(days: 14), account: bills, match: ["health"], order: 4),
            recurring("Car insurance", 1150, .yearly, anchor: today.adding(days: 75), account: bills, match: ["insurance"], order: 5),
            recurring("Streaming", 17, .monthly, anchor: today.adding(days: 12), account: bills, match: ["stream"], order: 6),
            recurring("Gym", 26, .fortnightly, anchor: nextThursday, account: bills, match: ["gym"], order: 7),
            recurring("Savings transfer", 200, .fortnightly, anchor: nextThursday, account: bills, order: 8),
            groceries,
            recurring("Eating out", 80, .weekly, anchor: monday, account: spending,
                      envelope: EnvelopeRule(categoryIDs: ["restaurants-and-cafes", "takeaway"]), order: 11),
            transport,
        ]

        let holiday = Period(
            name: "Holiday",
            color: .green,
            span: DateSpan(monday.adding(days: 42), monday.adding(days: 55)),
            pausedItemIDs: [groceries.id, transport.id]
        )
        items.append(BudgetItem(
            name: "Holiday spending",
            accountID: spending.id,
            segments: [ScheduleSegment(start: holiday.span.start, recurrence: Recurrence(.weekly, anchor: holiday.span.start), amount: .dollars(450))],
            periodID: holiday.id,
            sortIndex: 20
        ))
        items.append(BudgetItem(
            name: "Flights",
            accountID: spending.id,
            segments: [.once(today.adding(days: 10), amount: .dollars(780))],
            periodID: nil,
            sortIndex: 21
        ))
        items.append(BudgetItem(
            name: "Sold old bike",
            flow: .inflow,
            accountID: spending.id,
            segments: [.once(today.adding(days: 18), amount: .dollars(300))],
            sortIndex: 22
        ))

        let job = IncomeSource(
            name: "Example Pty Ltd",
            kind: .salaried,
            rates: [RateSegment(from: startOfYear, amount: .dollars(95_000), unit: .annual, superMode: .onTop)],
            paySchedule: Recurrence(.fortnightly, anchor: nextThursday),
            periodEndOffsetDays: 0,
            start: startOfYear,
            accountID: spending.id,
            match: MatchRule(patterns: ["example pty"])
        )

        return BudgetDocument(
            accounts: [bills, spending],
            items: items,
            incomes: [job],
            periods: [holiday],
            checkpoints: [BalanceCheckpoint(date: today, amount: .dollars(3200), note: "Starting balance")]
        )
    }

    /// A synthetic re-creation of a weekly budgeting spreadsheet, with fixed dates in 2027.
    /// Used by tests; the expected weekly totals are in the plan's Appendix C.
    public static func sheetScenario() -> BudgetDocument {
        let essentials = Account(id: fixtureID(1), name: "Essentials", sortIndex: 0)
        let spending = Account(id: fixtureID(2), name: "Spending", sortIndex: 1)
        let from = LocalDate(2026, 7, 1)

        func item(_ n: Int, _ name: String, _ cents: Int64, _ rule: RecurrenceRule, _ anchor: LocalDate,
                  account: Account, envelope: EnvelopeRule? = nil, order: Int) -> BudgetItem {
            BudgetItem(
                id: fixtureID(n),
                name: name,
                accountID: account.id,
                envelope: envelope,
                segments: [ScheduleSegment(id: fixtureID(n + 1000), start: from, recurrence: Recurrence(rule, anchor: anchor), amount: Money(cents: cents))],
                sortIndex: order
            )
        }

        let rent = item(10, "Rent", 70_000, .weekly, LocalDate(2027, 2, 1), account: essentials, order: 0)
        let food = item(11, "Food", 30_000, .weekly, LocalDate(2027, 2, 1), account: spending,
                        envelope: EnvelopeRule(categoryIDs: ["groceries"]), order: 1)
        let transport = item(12, "Transport", 2_000, .weekly, LocalDate(2027, 2, 1), account: spending, order: 2)
        let transfer = item(13, "Weekly transfer", 9_000, .weekly, LocalDate(2027, 2, 5), account: spending, order: 3)
        let phone = item(14, "Phone", 4_500, .monthly, LocalDate(2027, 1, 15), account: essentials, order: 4)
        let streaming = item(15, "Streaming", 1_299, .monthly, LocalDate(2027, 1, 28), account: essentials, order: 5)
        let gym = item(16, "Gym", 6_000, .monthly, LocalDate(2027, 1, 31), account: essentials, order: 6)
        let health = item(17, "Health", 16_000, .monthly, LocalDate(2027, 1, 10), account: essentials, order: 7)
        let car = item(18, "Car", 42_000, .monthly, LocalDate(2027, 1, 20), account: essentials, order: 8)
        var family = item(19, "Family", 90_000, .monthly, LocalDate(2027, 1, 1), account: essentials, order: 9)
        family.segments = [
            ScheduleSegment(id: fixtureID(1019), start: from, end: LocalDate(2027, 2, 28),
                            recurrence: Recurrence(.monthly, anchor: LocalDate(2027, 1, 1)), amount: Money(cents: 90_000)),
            ScheduleSegment(id: fixtureID(1119), start: LocalDate(2027, 3, 1),
                            recurrence: Recurrence(.monthly, anchor: LocalDate(2027, 1, 1)), amount: Money(cents: 78_000)),
        ]
        let card = item(20, "Credit card", 20_000, .fortnightly, LocalDate(2027, 2, 4), account: essentials, order: 10)

        let job = IncomeSource(
            id: fixtureID(30),
            name: "Contract",
            kind: .dayRate,
            rates: [RateSegment(id: fixtureID(1030), from: from, amount: .dollars(700), unit: .daily, superMode: .onTop)],
            paySchedule: Recurrence(.weekly, anchor: LocalDate(2027, 2, 3)),
            periodEndOffsetDays: 3,
            start: from,
            accountID: spending.id
        )

        let travel = Period(
            id: fixtureID(40),
            name: "Travel",
            color: .green,
            span: DateSpan(LocalDate(2027, 2, 15), LocalDate(2027, 3, 7)),
            pausedItemIDs: [rent.id, food.id, transport.id, transfer.id],
            unpaidIncomeIDs: [job.id]
        )
        let travelLine = BudgetItem(
            id: fixtureID(41), name: "Travel", accountID: spending.id,
            segments: [ScheduleSegment(id: fixtureID(1041), start: travel.span.start,
                                       recurrence: Recurrence(.weekly, anchor: LocalDate(2027, 2, 15)), amount: .dollars(450))],
            periodID: travel.id, sortIndex: 11
        )
        let prepaidRent = BudgetItem(
            id: fixtureID(42), name: "Rent (prepaid)", accountID: essentials.id,
            segments: [ScheduleSegment(id: fixtureID(1042), start: LocalDate(2027, 2, 15), end: LocalDate(2027, 2, 15),
                                       recurrence: .once(LocalDate(2027, 2, 15)), amount: .dollars(2100))],
            periodID: travel.id, sortIndex: 12
        )
        let bike = BudgetItem(
            id: fixtureID(43), name: "Sold bike", flow: .inflow, accountID: spending.id,
            segments: [ScheduleSegment(id: fixtureID(1043), start: LocalDate(2027, 3, 13), end: LocalDate(2027, 3, 13),
                                       recurrence: .once(LocalDate(2027, 3, 13)), amount: .dollars(350))],
            sortIndex: 13
        )

        return BudgetDocument(
            settings: Settings(historyWeeks: 8),
            accounts: [essentials, spending],
            items: [rent, food, transport, transfer, phone, streaming, gym, health, car, family, card, travelLine, prepaidRent, bike],
            incomes: [job],
            periods: [travel],
            checkpoints: [
                BalanceCheckpoint(id: fixtureID(50), date: LocalDate(2027, 2, 1), amount: .dollars(4000)),
                BalanceCheckpoint(id: fixtureID(51), date: LocalDate(2027, 3, 15), amount: .dollars(1450)),
            ]
        )
    }
}
