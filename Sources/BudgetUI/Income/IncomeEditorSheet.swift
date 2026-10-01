import BudgetCore
import SwiftUI

struct IncomeEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @State var draft: IncomeDraft
    @State private var riseDate = LocalDate(dayNumber: 0)
    @State private var riseAmount = Money.zero
    @State private var leaveStart = LocalDate(dayNumber: 0)
    @State private var leaveEnd = LocalDate(dayNumber: 0)
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Form {
                    basics
                    rate
                    schedule
                    taxAndSuper
                    employment
                    leave
                    Section {
                        TextField("Description contains", text: $draft.patterns, prompt: Text("e.g. your employer's name"))
                    } header: {
                        Text("Matching bank transactions")
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 470)
                Divider()
                PayPreview(draft: draft)
                    .frame(width: 270)
            }
            Divider()
            HStack {
                if !draft.isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save") {
                    model.upsertIncome(draft.build(), undoManager: undoManager)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(14)
        }
        .frame(width: 780, height: 700)
        .onAppear {
            riseDate = model.today
            riseAmount = draft.rateAmount
            leaveStart = model.today
            leaveEnd = model.today.adding(days: 4)
        }
        .confirmationDialog("Delete \(draft.source.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteIncome(draft.id, undoManager: undoManager)
                dismiss()
            }
        } message: {
            Text("Its pays disappear from every week. You can undo this.")
        }
    }

    private var basics: some View {
        Section {
            TextField("Name", text: $draft.source.name, prompt: Text("e.g. Employer or client"))
            Picker("Type", selection: $draft.source.kind) {
                ForEach(EmploymentKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            Picker("Paid into", selection: $draft.source.accountID) {
                Text("None").tag(UUID?.none)
                ForEach(model.document.sortedAccounts) { account in
                    Text(account.name).tag(UUID?.some(account.id))
                }
            }
        }
    }

    private var rate: some View {
        Section {
            LabeledContent(draft.source.kind == .abn ? "Fee" : "Pay") {
                HStack {
                    MoneyField(title: "Amount", value: $draft.rateAmount).frame(width: 130)
                    Picker("", selection: $draft.rateUnit) {
                        ForEach(RateUnit.allCases, id: \.self) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            if draft.source.kind != .abn {
                Picker("Super", selection: $draft.superMode) {
                    Text("On top of this amount").tag(SuperMode.onTop)
                    Text("Included in this amount (package)").tag(SuperMode.included)
                }
            }
            if draft.source.rates.count > 0 {
                ForEach(draft.source.rates) { rate in
                    HStack {
                        Text("From \(rate.from.dayMonth(includeYear: true))")
                        Spacer()
                        Text("\(Format.money(rate.amount)) \(rate.unit.label)").monospacedDigit()
                        if draft.source.rates.count > 1 {
                            Button {
                                draft.removeRate(rate.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .font(.callout)
                }
            }
            HStack {
                DatePicker("New rate from", selection: $riseDate.pickerDate, displayedComponents: .date)
                MoneyField(title: "New rate", value: $riseAmount).frame(width: 110)
                Button("Add") { draft.addRate(from: riseDate, amount: riseAmount) }
            }
        } header: {
            Text("Rate")
        } footer: {
            Text("Add a new rate for a pay rise or a new contract rate from a date.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var schedule: some View {
        Section {
            Picker("Paid", selection: $draft.frequency) {
                ForEach(PayFrequencyChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            DatePicker("Next pay day", selection: $draft.nextPay.pickerDate, displayedComponents: .date)
            Stepper(value: $draft.source.periodEndOffsetDays, in: 0...35) {
                Text(arrearsText)
            }
            LabeledContent("Work days") {
                HStack(spacing: 4) {
                    ForEach(Weekday.allCases, id: \.self) { day in
                        Toggle(String(day.shortName.prefix(2)), isOn: workDayBinding(day))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Pay days")
        } footer: {
            Text(draft.source.kind == .salaried
                 ? "Unpaid leave is taken off pro rata by work days."
                 : "Each pay is for the work days in its period, less public holidays and unpaid days. You can enter the actual days worked on a pay in the Cash Flow grid.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var taxAndSuper: some View {
        Section("Tax and super") {
            if draft.source.kind == .abn {
                Toggle("Registered for GST (charge 10% on top)", isOn: $draft.source.gstRegistered)
                Picker("Set aside income tax", selection: $draft.source.setAsideMode) {
                    Text("Estimate from the year's income").tag(SetAsideMode.estimate)
                    Text("A fixed percentage").tag(SetAsideMode.percent)
                    Text("Don't plan for it").tag(SetAsideMode.none)
                }
                if draft.source.setAsideMode == .percent {
                    LabeledContent("Percentage of each payment") {
                        MoneyField(title: "%", value: $draft.setAsidePercent).frame(width: 80)
                    }
                }
                LabeledContent("Super contribution each payment") {
                    MoneyField(title: "Contribution", value: $draft.source.salarySacrificePerPay).frame(width: 110)
                }
            } else {
                Toggle("Claim the tax-free threshold (turn off for a second job)", isOn: $draft.source.claimsTaxFreeThreshold)
                LabeledContent("Salary sacrifice each pay") {
                    MoneyField(title: "Pre-tax", value: $draft.source.salarySacrificePerPay).frame(width: 110)
                }
                LabeledContent("After-tax super each pay") {
                    MoneyField(title: "After tax", value: $draft.source.afterTaxSuperPerPay).frame(width: 110)
                }
            }
        }
    }

    private var employment: some View {
        Section("Employment") {
            DatePicker("Started", selection: $draft.source.start.pickerDate, displayedComponents: .date)
            Toggle("Finishes on a date", isOn: $draft.hasEnd)
            if draft.hasEnd {
                DatePicker("Last day", selection: $draft.end.pickerDate, displayedComponents: .date)
            }
        }
    }

    private var leave: some View {
        Section {
            ForEach(Array(draft.source.unpaidLeave.enumerated()), id: \.offset) { index, span in
                HStack {
                    Text(Format.span(span))
                    Text("(\(span.dayCount) days)").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        draft.source.unpaidLeave.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                DatePicker("From", selection: $leaveStart.pickerDate, displayedComponents: .date)
                DatePicker("to", selection: $leaveEnd.pickerDate, displayedComponents: .date)
                Button("Add") {
                    if let span = DateSpan.make(leaveStart, leaveEnd) { draft.addLeave(span) }
                }
                .disabled(leaveEnd < leaveStart)
            }
        } header: {
            Text("Unpaid leave")
        } footer: {
            Text("Days off without pay. Periods (like Travel) can also mark this income as unpaid.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var arrearsText: String {
        let days = draft.source.periodEndOffsetDays
        if days == 0 { return "Each pay covers work up to and including pay day" }
        let periodEnd = draft.nextPay.adding(days: -days)
        return "Each pay covers work up to \(days) day\(days == 1 ? "" : "s") before pay day (next: up to \(periodEnd.weekday.name) \(periodEnd.dayMonth()))"
    }

    private func workDayBinding(_ day: Weekday) -> Binding<Bool> {
        Binding(
            get: { draft.source.workDays.contains(day) },
            set: { on in
                if on {
                    if !draft.source.workDays.contains(day) { draft.source.workDays.append(day) }
                    draft.source.workDays.sort()
                } else {
                    draft.source.workDays.removeAll { $0 == day }
                }
            }
        )
    }
}

/// Live take-home pay for the draft's current rate.
private struct PayPreview: View {
    @Environment(AppModel.self) private var model
    let draft: IncomeDraft

    var body: some View {
        let quote = draft.quote(applyStandardDeduction: model.document.settings.applyStandardDeduction, year: model.today.financialYear)
        let row = quote.rows.first { $0.label == draft.frequency.label } ?? quote.rows[1]
        let b = row.breakdown
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Each \(draft.frequency.label.lowercased()) pay")
                    .font(.headline)
                if draft.source.kind != .salaried {
                    Text("Assuming \(draft.source.workDays.count) days a week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    previewLine(draft.source.kind == .abn ? "Fee" : "Gross", b.gross)
                    if b.salarySacrifice.isPositive { previewLine("Super (pre-tax)", -b.salarySacrifice) }
                    if draft.source.kind == .abn {
                        if b.gst.isPositive { previewLine("GST", b.gst) }
                    } else {
                        previewLine("Tax withheld", -b.withholding)
                    }
                    if b.afterTaxSuper.isPositive { previewLine("After-tax super", -b.afterTaxSuper) }
                    Divider().gridCellColumns(2)
                    previewLine("Lands in your account", b.net, bold: true)
                    if b.taxSetAside.isPositive { previewLine("Set aside for tax", -b.taxSetAside) }
                    if b.gstSetAside.isPositive { previewLine("Set aside for GST", -b.gstSetAside) }
                    if b.superGuarantee.isPositive { previewLine("Employer super", b.superGuarantee) }
                }
                Divider()
                Text("Year \(quote.data.year.label)")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    previewLine("Taxable income", quote.annualTax.taxableIncome)
                    previewLine("Tax and Medicare", quote.annualTax.total)
                    if draft.source.kind != .abn {
                        previewLine("Withheld if paid weekly", quote.annualWithheldIfWeekly)
                    }
                    previewLine("Super (all sources here)", quote.concessionalContributions)
                }
                if quote.exceedsConcessionalCap {
                    Label("Over the \(Format.wholeDollars(quote.data.concessionalCap)) concessional cap", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if quote.data.isEstimate {
                    Text(quote.data.notes.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color.secondary.opacity(0.05))
    }

    private func previewLine(_ title: String, _ amount: Money, bold: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.callout)
                .foregroundStyle(bold ? .primary : .secondary)
            Text(Format.money(amount))
                .font(.callout)
                .monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .gridColumnAlignment(.trailing)
        }
    }
}
