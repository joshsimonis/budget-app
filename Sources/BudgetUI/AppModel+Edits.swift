import BudgetCore
import Foundation

/// Named, undoable edits used by the views.
extension AppModel {
    func loadSample(undoManager: UndoManager?) {
        let sample = SampleData.demo(today: document.settings.timeZone.today())
        perform("Load Sample Budget", undoManager: undoManager) { $0 = sample }
        goToToday()
        saveNow()
    }

    func startBlank(balance: Money, undoManager: UndoManager?) {
        let today = document.settings.timeZone.today()
        perform("Start Budget", undoManager: undoManager) { doc in
            if doc.accounts.isEmpty {
                doc.accounts = [Account(name: "Spending", sortIndex: 0)]
            }
            doc.checkpoints.removeAll { $0.date == today }
            doc.checkpoints.append(BalanceCheckpoint(date: today, amount: balance, note: "Starting balance"))
        }
        saveNow()
    }

    // MARK: Items

    func upsertItem(_ item: BudgetItem, undoManager: UndoManager?) {
        perform(document.item(item.id) == nil ? "Add \(item.name)" : "Edit \(item.name)", undoManager: undoManager) { doc in
            if let index = doc.itemIndex(item.id) {
                doc.items[index] = item
            } else {
                var item = item
                item.sortIndex = (doc.items.map(\.sortIndex).max() ?? 0) + 1
                doc.items.append(item)
            }
        }
    }

    func deleteItem(_ id: UUID, undoManager: UndoManager?) {
        guard let item = document.item(id) else { return }
        perform("Delete \(item.name)", undoManager: undoManager) { doc in
            doc.items.removeAll { $0.id == id }
            for index in doc.periods.indices {
                doc.periods[index].pausedItemIDs.removeAll { $0 == id }
            }
        }
    }

    func setOverride(_ override: OccurrenceOverride, itemID: UUID, undoManager: UndoManager?) {
        guard let item = document.item(itemID) else { return }
        perform("Edit \(item.name)", undoManager: undoManager) { doc in
            guard let index = doc.itemIndex(itemID) else { return }
            ItemEdits.setOverride(override, in: &doc.items[index])
        }
    }

    func changeItem(_ itemID: UUID, from date: LocalDate, amount: Money, undoManager: UndoManager?) {
        guard let item = document.item(itemID) else { return }
        perform("Change \(item.name)", undoManager: undoManager) { doc in
            guard let index = doc.itemIndex(itemID) else { return }
            ItemEdits.changeFrom(date, in: &doc.items[index], amount: amount)
        }
    }

    func stopItem(_ itemID: UUID, from date: LocalDate, undoManager: UndoManager?) {
        guard let item = document.item(itemID) else { return }
        perform("Stop \(item.name)", undoManager: undoManager) { doc in
            guard let index = doc.itemIndex(itemID) else { return }
            ItemEdits.stop(&doc.items[index], from: date)
        }
    }

    // MARK: Income

    func upsertIncome(_ income: IncomeSource, undoManager: UndoManager?) {
        perform(document.income(income.id) == nil ? "Add \(income.name)" : "Edit \(income.name)", undoManager: undoManager) { doc in
            if let index = doc.incomeIndex(income.id) {
                doc.incomes[index] = income
            } else {
                var income = income
                income.sortIndex = (doc.incomes.map(\.sortIndex).max() ?? 0) + 1
                doc.incomes.append(income)
            }
        }
    }

    func deleteIncome(_ id: UUID, undoManager: UndoManager?) {
        guard let income = document.income(id) else { return }
        perform("Delete \(income.name)", undoManager: undoManager) { doc in
            doc.incomes.removeAll { $0.id == id }
            for index in doc.periods.indices {
                doc.periods[index].unpaidIncomeIDs.removeAll { $0 == id }
            }
        }
    }

    func setPayOverride(_ override: OccurrenceOverride, incomeID: UUID, undoManager: UndoManager?) {
        guard let income = document.income(incomeID) else { return }
        perform("Edit \(income.name) Pay", undoManager: undoManager) { doc in
            guard let index = doc.incomeIndex(incomeID) else { return }
            IncomeEdits.setOverride(override, in: &doc.incomes[index])
        }
    }

    func setDaysWorked(_ hundredths: Int?, payDate: LocalDate, incomeID: UUID, undoManager: UndoManager?) {
        guard document.income(incomeID) != nil else { return }
        perform("Set Days Worked", undoManager: undoManager) { doc in
            guard let index = doc.incomeIndex(incomeID) else { return }
            IncomeEdits.setDaysWorked(hundredths, payDate: payDate, in: &doc.incomes[index])
        }
    }

    // MARK: Periods

    func upsertPeriod(_ period: Period, undoManager: UndoManager?) {
        perform(document.period(period.id) == nil ? "Add \(period.name)" : "Edit \(period.name)", undoManager: undoManager) { doc in
            if let index = doc.periodIndex(period.id) {
                doc.periods[index] = period
            } else {
                doc.periods.append(period)
            }
        }
    }

    func deletePeriod(_ id: UUID, undoManager: UndoManager?) {
        guard let period = document.period(id) else { return }
        perform("Delete \(period.name)", undoManager: undoManager) { doc in
            doc.periods.removeAll { $0.id == id }
            doc.items.removeAll { $0.periodID == id }
        }
    }

    // MARK: Balances and settings

    /// Sets (or with nil, removes) the balance you know at the start of `date`.
    func setCheckpoint(_ amount: Money?, on date: LocalDate, undoManager: UndoManager?) {
        perform(amount == nil ? "Remove Balance" : "Set Balance", undoManager: undoManager) { doc in
            doc.checkpoints.removeAll { $0.date == date }
            if let amount {
                doc.checkpoints.append(BalanceCheckpoint(date: date, amount: amount))
                doc.checkpoints.sort { $0.date < $1.date }
            }
        }
    }

    func updateSettings(_ name: String = "Change Settings", undoManager: UndoManager?, _ change: (inout BudgetCore.Settings) -> Void) {
        perform(name, undoManager: undoManager) { change(&$0.settings) }
    }

    func upsertAccount(_ account: Account, undoManager: UndoManager?) {
        perform("Edit Accounts", undoManager: undoManager) { doc in
            if let index = doc.accounts.firstIndex(where: { $0.id == account.id }) {
                doc.accounts[index] = account
            } else {
                var account = account
                account.sortIndex = (doc.accounts.map(\.sortIndex).max() ?? -1) + 1
                doc.accounts.append(account)
            }
        }
    }

    func deleteAccount(_ id: UUID, undoManager: UndoManager?) {
        perform("Delete Account", undoManager: undoManager) { doc in
            doc.accounts.removeAll { $0.id == id }
            for index in doc.items.indices where doc.items[index].accountID == id {
                doc.items[index].accountID = nil
            }
            for index in doc.incomes.indices where doc.incomes[index].accountID == id {
                doc.incomes[index].accountID = nil
            }
        }
    }
}
