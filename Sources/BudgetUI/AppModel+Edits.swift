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

// MARK: Reconciliation

extension AppModel {
    /// Links bank transactions to a planned occurrence by hand.
    func link(_ transactionIDs: [String], to key: OccurrenceKey, undoManager: UndoManager?) {
        perform("Link Transaction", undoManager: undoManager) { doc in
            doc.reconciliation.manualLinks.removeAll { $0.occurrence == key }
            for index in doc.reconciliation.manualLinks.indices {
                doc.reconciliation.manualLinks[index].transactionIDs.removeAll { transactionIDs.contains($0) }
            }
            doc.reconciliation.manualLinks.removeAll { $0.transactionIDs.isEmpty }
            doc.reconciliation.manualLinks.append(ManualLink(occurrence: key, transactionIDs: transactionIDs))
            doc.reconciliation.markedPaid.removeAll { $0 == key }
            doc.reconciliation.ignoredTransactionIDs.removeAll { transactionIDs.contains($0) }
        }
    }

    /// Removes a match. A manual link is deleted; an automatic one is undone by ignoring the transaction.
    func unlink(_ key: OccurrenceKey, undoManager: UndoManager?) {
        let reconciliation = projection.flow(key)?.reconciliation
        perform("Unlink Transaction", undoManager: undoManager) { doc in
            if doc.reconciliation.manualLinks.contains(where: { $0.occurrence == key }) {
                doc.reconciliation.manualLinks.removeAll { $0.occurrence == key }
            } else if let ids = reconciliation?.transactionIDs {
                for id in ids where !doc.reconciliation.ignoredTransactionIDs.contains(id) {
                    doc.reconciliation.ignoredTransactionIDs.append(id)
                }
            }
            doc.reconciliation.markedPaid.removeAll { $0 == key }
        }
    }

    func setMarkedPaid(_ paid: Bool, key: OccurrenceKey, undoManager: UndoManager?) {
        perform(paid ? "Mark as Paid" : "Mark as Unpaid", undoManager: undoManager) { doc in
            doc.reconciliation.markedPaid.removeAll { $0 == key }
            if paid { doc.reconciliation.markedPaid.append(key) }
        }
    }

    func setIgnored(_ ignored: Bool, transactionID: String, undoManager: UndoManager?) {
        perform(ignored ? "Ignore Transaction" : "Stop Ignoring Transaction", undoManager: undoManager) { doc in
            doc.reconciliation.ignoredTransactionIDs.removeAll { $0 == transactionID }
            if ignored { doc.reconciliation.ignoredTransactionIDs.append(transactionID) }
        }
    }

    /// Bank transactions near an occurrence that could be linked to it.
    func linkCandidates(for flow: PlannedFlow) -> [DatedTransaction] {
        guard let bank else { return [] }
        let zone = document.settings.timeZone
        let included = Set(document.accounts.filter(\.includedInTotal).compactMap(\.upAccountID))
        let low = flow.date.adding(days: -14)
        let high = flow.date.adding(days: 14)
        return bank.transactions
            .filter { included.contains($0.accountID) && $0.amount.isPositive == flow.plannedAmount.isPositive }
            .map { DatedTransaction(transaction: $0, date: zone.localDate(for: $0.createdAt)) }
            .filter { $0.date >= low && $0.date <= high }
            .sorted { abs($0.date - flow.date) < abs($1.date - flow.date) }
    }

    func describe(_ key: OccurrenceKey) -> String {
        let name = document.sourceName(key.sourceID) ?? "Item"
        return "\(name), \(key.originalDate.dayMonth())"
    }
}
