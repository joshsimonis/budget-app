import BudgetCore
import SwiftUI

struct IncomeListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @State private var draft: IncomeDraft?
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            if model.document.incomes.isEmpty {
                ContentUnavailableView {
                    Label("No income yet", systemImage: "banknote")
                } description: {
                    Text("Add a salary, a day-rate contract or ABN work. Tax, super and take-home pay are worked out for each pay.")
                } actions: {
                    Button("Add Salary") { newIncome(.salaried) }
                    Button("Add Day Rate") { newIncome(.dayRate) }
                    Button("Add ABN Work") { newIncome(.abn) }
                }
            } else {
                Table(model.document.incomes.filter { !$0.archived }, selection: $selection) {
                    TableColumn("Name") { source in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                            Text(source.kind.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Rate") { source in
                        Text(GridBuilder.incomeSubtitle(source, today: model.today)).foregroundStyle(.secondary)
                    }
                    TableColumn("Next pay") { source in
                        if let pay = nextPay(source) {
                            Text("\(Format.money(pay.received)) on \(pay.payDate.dayMonth())").monospacedDigit()
                        } else {
                            Text("–")
                        }
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Employment") { source in
                        Text(source.end.map { "Until \($0.dayMonth(includeYear: true))" } ?? "Ongoing")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 120)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Divider()
                    }
                    Button("Delete", role: .destructive) {
                        for id in ids { model.deleteIncome(id, undoManager: undoManager) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .frame(minHeight: 160)
                Divider()
                TaxYearPanel()
            }
        }
        .navigationTitle("Income")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "pay-calculator")
                } label: {
                    Label("Pay Calculator", systemImage: "function")
                }
                Menu {
                    Button("Salary") { newIncome(.salaried) }
                    Button("Day rate (payroll)") { newIncome(.dayRate) }
                    Button("ABN contractor") { newIncome(.abn) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $draft) { draft in
            IncomeEditorSheet(draft: draft)
        }
    }

    private func nextPay(_ source: IncomeSource) -> PayEvent? {
        model.projection.payEvents.first { $0.sourceID == source.id && $0.payDate >= model.today && $0.state == .planned }
    }

    private func newIncome(_ kind: EmploymentKind) {
        draft = IncomeDraft(newKind: kind, today: model.today, accountID: model.document.sortedAccounts.first?.id)
    }

    private func edit(_ id: UUID) {
        guard let source = model.document.income(id) else { return }
        draft = IncomeDraft(source: source, today: model.today)
    }
}

/// Tax position for each financial year, from the planned pays.
struct TaxYearPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.projection.estimates) { estimate in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Tax year \(estimate.year.label)").font(.headline)
                            if estimate.isEstimate {
                                Text("estimate")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                            line("Income (\(estimate.payCount) pays)", estimate.grossIncome)
                            if estimate.preTaxContributions.isPositive { line("Pre-tax super", -estimate.preTaxContributions) }
                            if estimate.standardDeduction.isPositive { line("Standard deduction", -estimate.standardDeduction) }
                            line("Taxable income", estimate.taxableIncome)
                            line("Income tax", estimate.tax.incomeTax)
                            if estimate.tax.lowIncomeTaxOffset.isPositive { line("Low income offset", -estimate.tax.lowIncomeTaxOffset) }
                            line("Medicare levy", estimate.tax.medicareLevy)
                            line("Tax withheld", estimate.withheld)
                            if estimate.setAside.isPositive { line("Set aside (ABN)", estimate.setAside) }
                            Divider().gridCellColumns(2)
                            line(estimate.position.isNegative ? "Likely to owe" : "Likely refund", estimate.position.magnitude, bold: true,
                                 color: estimate.position.isNegative ? .orange : .green)
                            line("Super (employer + yours)", estimate.concessionalContributions)
                        }
                        if estimate.exceedsConcessionalCap {
                            Label("Over the \(Format.wholeDollars(estimate.concessionalCap)) concessional cap", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(12)
                    .frame(width: 300, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                }
            }
            .padding(14)
        }
        .frame(height: 330)
    }

    private func line(_ title: String, _ amount: Money, bold: Bool = false, color: Color = .primary) -> some View {
        GridRow {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(Format.money(amount))
                .font(.callout)
                .monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(color)
                .gridColumnAlignment(.trailing)
        }
    }
}
