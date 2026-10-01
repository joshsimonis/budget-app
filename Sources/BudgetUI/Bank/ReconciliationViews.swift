import BudgetCore
import SwiftUI

/// Bank status for one planned occurrence, with link / unlink / mark-paid actions.
struct ReconciliationSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let flow: PlannedFlow
    @State private var choosing = false

    var body: some View {
        if model.projection.mode == .bank, flow.state == .planned, let status = flow.status {
            VStack(alignment: .leading, spacing: 6) {
                switch status {
                case .matched:
                    ForEach(flow.reconciliation?.transactionIDs ?? [], id: \.self) { id in
                        if let transaction = model.bank?.transaction(id) {
                            TransactionLine(transaction: transaction, symbol: "checkmark.circle.fill", tint: .green)
                        }
                    }
                    Button(flow.reconciliation?.isManual == true ? "Unlink" : "That's not it") {
                        model.unlink(flow.key, undoManager: undoManager)
                    }
                    .controlSize(.small)
                case .markedPaid:
                    Label("Marked as paid", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Button("Mark as not paid") { model.setMarkedPaid(false, key: flow.key, undoManager: undoManager) }
                        .controlSize(.small)
                case .pending, .missed, .upcoming, .assumed:
                    Label(message(for: status), systemImage: symbol(for: status))
                        .font(.callout)
                        .foregroundStyle(status == .missed ? .red : (status == .pending ? .orange : .secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if status != .upcoming {
                            Button("Mark as paid") { model.setMarkedPaid(true, key: flow.key, undoManager: undoManager) }
                        }
                        Button(choosing ? "Hide transactions" : "Choose transaction…") { choosing.toggle() }
                    }
                    .controlSize(.small)
                    if choosing {
                        let candidates = model.linkCandidates(for: flow)
                        if candidates.isEmpty {
                            Text("No transactions within two weeks.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(candidates.prefix(12)) { dated in
                            Button {
                                model.link([dated.transaction.id], to: flow.key, undoManager: undoManager)
                                choosing = false
                            } label: {
                                TransactionLine(transaction: dated.transaction, date: dated.date, symbol: "link", tint: .accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
        }
    }

    private func message(for status: OccurrenceStatus) -> String {
        switch status {
        case .pending: "Not at the bank yet. Counted as still to come today."
        case .missed: "Hasn't shown up at the bank. It's left out of your balance until you mark it paid or link a transaction."
        case .upcoming: "Still to come."
        case .assumed: "Not checked against Up. Add matching text to this item to tick it off automatically."
        case .matched, .markedPaid: ""
        }
    }

    private func symbol(for status: OccurrenceStatus) -> String {
        switch status {
        case .pending: "clock"
        case .missed: "exclamationmark.triangle.fill"
        default: "info.circle"
        }
    }
}

/// One bank transaction on a line.
struct TransactionLine: View {
    @Environment(AppModel.self) private var model
    let transaction: BankTransaction
    var date: LocalDate?
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        let day = date ?? model.document.settings.timeZone.localDate(for: transaction.createdAt)
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).font(.caption)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(transaction.description).lineLimit(1)
                Text([day.dayMonth(), model.bank?.account(transaction.accountID)?.name, transaction.status == .held ? "pending" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.signed(transaction.amount))
                .monospacedDigit()
                .foregroundStyle(transaction.amount.isPositive ? .green : .primary)
        }
        .contentShape(Rectangle())
    }
}

/// Transactions in a column that aren't part of the plan.
struct UnplannedTransactionsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    let bucket: Bucket
    let isInflow: Bool

    var body: some View {
        let transactions = model.projection.unplanned.filter {
            bucket.span.contains($0.date) && $0.transaction.balanceDelta.isPositive == isInflow
        }
        let ignored = Set(model.document.reconciliation.ignoredTransactionIDs)
        VStack(alignment: .leading, spacing: 10) {
            Text("These moved your balance but aren't in your plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(transactions) { dated in
                VStack(alignment: .leading, spacing: 4) {
                    TransactionLine(transaction: dated.transaction, date: dated.date)
                    HStack {
                        Button("Make it a regular item…") {
                            let draft = ItemDraft(from: dated, accountID: model.document.accounts.first { $0.upAccountID == dated.transaction.accountID }?.id)
                            dismiss()
                            model.presentedItemDraft = draft
                        }
                        Button("Add as a one-off") {
                            model.addOneOff(from: dated, undoManager: undoManager)
                        }
                        Button(ignored.contains(dated.transaction.id) ? "Ignored" : "Ignore") {
                            model.setIgnored(!ignored.contains(dated.transaction.id), transactionID: dated.transaction.id, undoManager: undoManager)
                        }
                    }
                    .controlSize(.small)
                }
                Divider()
            }
        }
    }
}

extension ItemDraft {
    /// A bill prefilled from a bank transaction (monthly from that date, matching its description).
    init(from dated: DatedTransaction, accountID: UUID?) {
        let transaction = dated.transaction
        self.init(newKind: transaction.amount.isPositive ? .moneyIn : .bill, today: dated.date, accountID: accountID, anchor: dated.date)
        name = transaction.description
        amount = transaction.amount.magnitude
        patterns = TextMatch.normalize(transaction.description)
    }
}

extension AppModel {
    /// Adds a one-off item for a transaction and links the two.
    func addOneOff(from dated: DatedTransaction, undoManager: UndoManager?) {
        let transaction = dated.transaction
        let item = BudgetItem(
            name: transaction.description,
            flow: transaction.amount.isPositive ? .inflow : .outflow,
            accountID: document.accounts.first { $0.upAccountID == transaction.accountID }?.id,
            segments: [.once(dated.date, amount: transaction.amount.magnitude)]
        )
        perform("Add \(item.name)", undoManager: undoManager) { doc in
            var added = item
            added.sortIndex = (doc.items.map(\.sortIndex).max() ?? 0) + 1
            doc.items.append(added)
            doc.reconciliation.manualLinks.append(ManualLink(occurrence: OccurrenceKey(sourceID: item.id, originalDate: dated.date),
                                                             transactionIDs: [transaction.id]))
        }
    }
}
