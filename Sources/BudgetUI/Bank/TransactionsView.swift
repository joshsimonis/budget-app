import BudgetCore
import SwiftUI

struct TransactionRow: Identifiable {
    let transaction: BankTransaction
    let date: LocalDate
    let accountName: String
    let categoryName: String
    var id: String { transaction.id }
}

struct TransactionsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var accountFilter: String?
    @State private var selection = Set<String>()

    var body: some View {
        Group {
            if let bank = model.bank {
                Table(rows(bank), selection: $selection) {
                    TableColumn("Date") { row in
                        Text(row.date.dayMonth(includeYear: row.date.year != model.today.year))
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Description") { row in
                        HStack(spacing: 4) {
                            Text(row.transaction.description)
                            if row.transaction.status == .held {
                                Text("pending")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    TableColumn("Account") { row in
                        Text(row.accountName).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Category") { row in
                        Text(row.categoryName).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 130)
                    TableColumn("Amount") { row in
                        Text(Format.signed(row.transaction.amount))
                            .monospacedDigit()
                            .foregroundStyle(row.transaction.amount.isPositive ? .green : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110)
                }
                .searchable(text: $search, placement: .toolbar)
            } else {
                ContentUnavailableView {
                    Label("Up isn't connected", systemImage: "creditcard")
                } description: {
                    Text("Connect your Up account in Settings to see transactions and reconcile your plan.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            }
        }
        .navigationTitle("Transactions")
        .toolbar {
            if let bank = model.bank {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Account", selection: $accountFilter) {
                        Text("All accounts").tag(String?.none)
                        ForEach(bank.accounts) { account in
                            Text(account.name).tag(String?.some(account.id))
                        }
                    }
                    .frame(width: 180)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.syncStatus == .syncing)
                }
            }
        }
    }

    private func rows(_ bank: BankCache) -> [TransactionRow] {
        let zone = model.document.settings.timeZone
        let query = search.trimmingCharacters(in: .whitespaces)
        return bank.transactions.reversed()
            .filter { accountFilter == nil || $0.accountID == accountFilter }
            .filter { query.isEmpty || $0.description.localizedCaseInsensitiveContains(query) }
            .map { transaction in
                TransactionRow(
                    transaction: transaction,
                    date: zone.localDate(for: transaction.createdAt),
                    accountName: bank.account(transaction.accountID)?.name ?? "",
                    categoryName: transaction.isTransfer ? "Transfer" : (bank.category(transaction.categoryID)?.name ?? "")
                )
            }
    }
}
