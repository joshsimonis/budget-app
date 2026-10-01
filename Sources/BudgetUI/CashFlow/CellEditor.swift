import BudgetCore
import SwiftUI

/// The popover for a grid cell.
struct CellEditor: View {
    @Environment(AppModel.self) private var model
    let row: CashFlowRow
    let bucketIndex: Int

    var body: some View {
        let bucket = model.grid.buckets[bucketIndex]
        let current = model.grid.row(row.id) ?? row
        let keys = current.cells.indices.contains(bucketIndex) ? current.cells[bucketIndex].keys.sorted() : []
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title).font(.headline)
                Text(Format.span(bucket.span))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if current.kind == .other {
                        UnplannedTransactionsEditor(bucket: bucket, isInflow: current.isInflow)
                    }
                    ForEach(keys, id: \.self) { key in
                        editor(for: key, kind: current.kind)
                        if key != keys.last { Divider() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)
        }
        .padding(14)
        .frame(width: 400)
    }

    @ViewBuilder
    private func editor(for key: OccurrenceKey, kind: RowKind) -> some View {
        switch kind {
        case .item:
            if let flow = model.projection.flow(key), let item = model.item(key.sourceID) {
                ItemOccurrenceEditor(item: item, flow: flow)
                ReconciliationSection(flow: flow)
            }
        case .envelope:
            if let period = model.projection.envelope(key), let item = model.item(key.sourceID) {
                EnvelopePeriodEditor(item: item, period: period)
            }
        case .income:
            if let event = model.projection.payEvent(key), let source = model.income(key.sourceID) {
                PayEventEditor(source: source, event: event)
                if let flow = model.projection.flow(key) {
                    ReconciliationSection(flow: flow)
                }
            }
        case .setAside:
            if let flow = model.projection.flow(key) {
                SetAsideInfo(flow: flow)
            }
        case .other:
            EmptyView()
        }
    }
}

private struct StateBadge: View {
    let state: FlowState

    var body: some View {
        switch state {
        case .planned:
            EmptyView()
        case .skipped:
            badge("Skipped", .secondary)
        case .paused:
            badge("Paused by a period", .secondary)
        case .unpaid:
            badge("Unpaid", .orange)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// Edit one occurrence of a bill or other item.
struct ItemOccurrenceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let item: BudgetItem
    let flow: PlannedFlow
    @State private var amount = Money.zero
    @State private var fromHere = Money.zero
    @State private var moveTo = LocalDate(dayNumber: 0)
    @State private var showMore = false

    private var original: LocalDate { flow.key.originalDate }
    private var override: OccurrenceOverride? { item.override(for: original) }
    private var scheduledAmount: Money { item.segment(covering: original)?.amount ?? flow.plannedAmount.magnitude }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.date(flow.date)).font(.subheadline.weight(.semibold))
                if flow.date != original {
                    Text("scheduled \(original.dayMonth())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StateBadge(state: flow.state)
            }
            HStack {
                Text("Amount")
                MoneyField(title: "Amount", value: $amount)
                    .frame(width: 120)
                Button("Set") {
                    var updated = override ?? OccurrenceOverride(originalDate: original)
                    updated.amount = amount == scheduledAmount ? nil : amount
                    model.setOverride(updated, itemID: item.id, undoManager: undoManager)
                }
                .disabled(amount == flow.plannedAmount.magnitude)
            }
            Toggle("Skip this one", isOn: Binding(
                get: { override?.skip ?? false },
                set: { skip in
                    var updated = override ?? OccurrenceOverride(originalDate: original)
                    updated.skip = skip
                    model.setOverride(updated, itemID: item.id, undoManager: undoManager)
                }
            ))
            DisclosureGroup("Move, change or stop", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        DatePicker("Move to", selection: $moveTo.pickerDate, displayedComponents: .date)
                        Button("Move") {
                            var updated = override ?? OccurrenceOverride(originalDate: original)
                            updated.movedTo = moveTo == original ? nil : moveTo
                            model.setOverride(updated, itemID: item.id, undoManager: undoManager)
                        }
                        .disabled(moveTo == flow.date)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From \(original.dayMonth()) on, every \(item.name) is")
                            .font(.callout)
                        HStack {
                            MoneyField(title: "New amount", value: $fromHere)
                                .frame(width: 120)
                            Button("Apply") {
                                model.changeItem(item.id, from: original, amount: fromHere, undoManager: undoManager)
                            }
                            .disabled(fromHere == scheduledAmount)
                        }
                        Text("Use this for a price change you've been told about.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if override != nil {
                            Button("Reset this one") {
                                model.setOverride(OccurrenceOverride(originalDate: original), itemID: item.id, undoManager: undoManager)
                            }
                        }
                        Spacer()
                        Button("Stop from here", role: .destructive) {
                            model.stopItem(item.id, from: original, undoManager: undoManager)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .onAppear {
            amount = flow.plannedAmount.magnitude
            fromHere = scheduledAmount
            moveTo = flow.date
        }
    }
}

/// Edit one period of an envelope (e.g. one week of groceries).
struct EnvelopePeriodEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let item: BudgetItem
    let period: EnvelopePeriod
    @State private var amount = Money.zero
    @State private var fromHere = Money.zero

    private var start: LocalDate { period.key.originalDate }
    private var override: OccurrenceOverride? { item.override(for: start) }
    private var scheduled: Money { item.segment(covering: start)?.amount ?? period.fullBudget }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Format.span(period.span)).font(.subheadline.weight(.semibold))
                Spacer()
                StateBadge(state: period.state)
            }
            if period.budget != period.fullBudget && period.state == .planned {
                Text("\(Format.money(period.budget)) after days paused by a period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let spend = period.spend {
                let left = period.budget - spend.spent
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(1, max(0, Double(spend.spent.cents) / Double(max(1, period.budget.cents)))))
                        .tint(left.isNegative ? .red : .accentColor)
                    Text(left.isNegative
                         ? "Spent \(Format.money(spend.spent)), \(Format.money(-left)) over budget"
                         : "Spent \(Format.money(spend.spent)), \(Format.money(left)) left")
                        .font(.callout)
                        .foregroundStyle(left.isNegative ? .red : .primary)
                    ForEach(spend.transactionIDs.suffix(8), id: \.self) { id in
                        if let transaction = model.bank?.transaction(id) {
                            TransactionLine(transaction: transaction)
                                .font(.caption)
                        }
                    }
                }
            }
            HStack {
                Text("Budget")
                MoneyField(title: "Budget", value: $amount)
                    .frame(width: 120)
                Button("Set") {
                    var updated = override ?? OccurrenceOverride(originalDate: start)
                    updated.amount = amount == scheduled ? nil : amount
                    model.setOverride(updated, itemID: item.id, undoManager: undoManager)
                }
                .disabled(amount == period.fullBudget)
            }
            Toggle("Skip this period", isOn: Binding(
                get: { override?.skip ?? false },
                set: { skip in
                    var updated = override ?? OccurrenceOverride(originalDate: start)
                    updated.skip = skip
                    model.setOverride(updated, itemID: item.id, undoManager: undoManager)
                }
            ))
            HStack {
                Text("From here on")
                MoneyField(title: "New budget", value: $fromHere)
                    .frame(width: 120)
                Button("Apply") {
                    model.changeItem(item.id, from: start, amount: fromHere, undoManager: undoManager)
                }
                .disabled(fromHere == scheduled)
            }
        }
        .onAppear {
            amount = period.fullBudget
            fromHere = scheduled
        }
    }
}

/// One pay: the breakdown, days worked, missed pay and the amount actually received.
struct PayEventEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let source: IncomeSource
    let event: PayEvent
    @State private var daysText = ""
    @State private var actual = Money.zero

    private var override: OccurrenceOverride? { source.override(for: event.originalDate) }

    var body: some View {
        let b = event.breakdown
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.date(event.payDate)).font(.subheadline.weight(.semibold))
                Text("for \(Format.span(event.workPeriod))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StateBadge(state: event.state)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                line("Gross", b.gross)
                if b.salarySacrifice.isPositive { line(source.kind == .abn ? "Super contribution" : "Salary sacrifice", -b.salarySacrifice) }
                if source.kind == .abn {
                    if b.gst.isPositive { line("GST charged", b.gst) }
                } else {
                    line("Tax withheld", -b.withholding)
                }
                if b.afterTaxSuper.isPositive { line("After-tax super", -b.afterTaxSuper) }
                Divider().gridCellColumns(2)
                line("Net pay", b.net, bold: true)
                if b.superGuarantee.isPositive { line("Employer super", b.superGuarantee, secondary: true) }
                if b.taxSetAside.isPositive { line("Set aside for tax", -b.taxSetAside, secondary: true) }
                if b.gstSetAside.isPositive { line("Set aside for GST", -b.gstSetAside, secondary: true) }
            }
            if b.usesEstimatedTables {
                Label("Uses estimated tax tables for \(event.year.label).", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if event.unpaidDays > 0 {
                Label("\(event.unpaidDays) unpaid day\(event.unpaidDays == 1 ? "" : "s") in this pay", systemImage: "calendar.badge.minus")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if event.incomeLost.isPositive {
                Text("\(Format.money(event.incomeLost)) less than a normal pay")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if source.kind != .salaried {
                Divider()
                HStack {
                    Text("Days worked")
                    TextField("Days", text: $daysText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Button("Set") {
                        if let days = Format.parseDays(daysText) {
                            model.setDaysWorked(days, payDate: event.originalDate, incomeID: source.id, undoManager: undoManager)
                        }
                    }
                    .disabled(Format.parseDays(daysText) == nil)
                    if event.daysOverridden {
                        Button("Use default (\(Format.days(event.defaultDaysHundredths ?? 0)))") {
                            model.setDaysWorked(nil, payDate: event.originalDate, incomeID: source.id, undoManager: undoManager)
                        }
                    }
                }
                Text("Default: work days in the period, less public holidays and unpaid days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Toggle("Missed pay (nothing paid)", isOn: Binding(
                get: { override?.skip ?? false },
                set: { skip in
                    var updated = override ?? OccurrenceOverride(originalDate: event.originalDate)
                    updated.skip = skip
                    model.setPayOverride(updated, incomeID: source.id, undoManager: undoManager)
                }
            ))
            HStack {
                Text("Actually received")
                MoneyField(title: "Net", value: $actual)
                    .frame(width: 120)
                Button("Set") {
                    var updated = override ?? OccurrenceOverride(originalDate: event.originalDate)
                    updated.amount = actual
                    model.setPayOverride(updated, incomeID: source.id, undoManager: undoManager)
                }
                if event.netOverride != nil {
                    Button("Clear") {
                        var updated = override ?? OccurrenceOverride(originalDate: event.originalDate)
                        updated.amount = nil
                        model.setPayOverride(updated, incomeID: source.id, undoManager: undoManager)
                    }
                }
            }
        }
        .onAppear {
            daysText = Format.days(event.daysWorkedHundredths ?? 0)
            actual = event.received
        }
    }

    private func line(_ title: String, _ amount: Money, bold: Bool = false, secondary: Bool = false) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(secondary ? .secondary : .primary)
            Text(Format.money(amount))
                .monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(secondary ? .secondary : .primary)
                .gridColumnAlignment(.trailing)
        }
    }
}

struct SetAsideInfo: View {
    let flow: PlannedFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Format.date(flow.date)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(Format.money(flow.amount.magnitude)).monospacedDigit()
            }
            Text(flow.kind == .gstSetAside
                 ? "GST you charged on this invoice. It goes to the ATO with your BAS, so it's taken out of your spendable cash."
                 : "Income tax isn't withheld from ABN income, so this share of the year's estimated tax is put aside.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Enter the balance you know at the start of a day (the sheet's "Cash - Bank").
struct CheckpointEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    let bucket: Bucket
    @State private var date = LocalDate(dayNumber: 0)
    @State private var amount = Money.zero

    var body: some View {
        let existing = model.document.checkpoints.first { $0.date == date }
        VStack(alignment: .leading, spacing: 10) {
            Text("Bank balance").font(.headline)
            Text("What's in your account at the start of this day. The running total restarts from here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Date", selection: $date.pickerDate,
                       in: bucket.span.start.pickerDate...bucket.span.end.pickerDate,
                       displayedComponents: .date)
            HStack {
                Text("Balance")
                MoneyField(title: "Balance", value: $amount)
                    .frame(width: 140)
            }
            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive) {
                        model.setCheckpoint(nil, on: date, undoManager: undoManager)
                        dismiss()
                    }
                }
                Spacer()
                Button("Save") {
                    model.setCheckpoint(amount, on: date, undoManager: undoManager)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            let today = model.projection.today
            let existingInBucket = model.document.checkpoints.first { bucket.span.contains($0.date) }
            date = existingInBucket?.date ?? (bucket.span.contains(today) ? today : bucket.span.start)
            amount = existingInBucket?.amount ?? model.projection.ledger(on: date)?.opening ?? .zero
        }
    }
}
