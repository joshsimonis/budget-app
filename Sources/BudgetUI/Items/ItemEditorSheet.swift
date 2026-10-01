import BudgetCore
import SwiftUI

/// Add or edit a bill, envelope, one-off or regular money-in item.
struct ItemEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @State var draft: ItemDraft
    @State private var changeDate = LocalDate(dayNumber: 0)
    @State private var changeAmount = Money.zero
    @State private var confirmDelete = false

    private var historyStart: LocalDate { model.projection.horizon.start }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Rent, Phone, Groceries"))
                    Picker("Type", selection: $draft.kind) {
                        ForEach(ItemKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    Picker("Account", selection: $draft.accountID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.document.sortedAccounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    if !model.document.periods.isEmpty {
                        Picker("Happens", selection: $draft.periodID) {
                            Text("Any time").tag(UUID?.none)
                            ForEach(model.document.periods) { period in
                                Text("Only during \(period.name)").tag(UUID?.some(period.id))
                            }
                        }
                    }
                }

                if draft.kind == .oneOff {
                    Section("Amount and date") {
                        LabeledContent("Amount") {
                            MoneyField(title: "Amount", value: $draft.amount).frame(width: 140)
                        }
                        DatePicker("Date", selection: $draft.anchor.pickerDate, displayedComponents: .date)
                        Toggle("This is money coming in (e.g. selling something)", isOn: $draft.oneOffInflow)
                    }
                } else {
                    scheduleSection
                }

                if draft.kind == .envelope {
                    Section {
                        TextField("Up categories", text: $draft.categories, prompt: Text("e.g. groceries, takeaway"))
                        TextField("Up tags", text: $draft.tags, prompt: Text("e.g. Holiday"))
                    } header: {
                        Text("Spending that counts against this envelope")
                    } footer: {
                        Text("Up category ids or tags, separated by commas. A parent category includes its children.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Description contains", text: $draft.patterns, prompt: Text("e.g. telstra, optus"))
                } header: {
                    Text("Matching bank transactions")
                } footer: {
                    Text("Text from the Up transaction description, separated by commas. Used to tick this off when it's paid.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !draft.isNew && draft.kind != .oneOff {
                    historySection
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !draft.isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save") {
                    model.upsertItem(draft.build(historyStart: historyStart), undoManager: undoManager)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(14)
        }
        .frame(width: 560, height: 660)
        .onAppear {
            changeDate = model.today
            changeAmount = draft.amount
        }
        .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteItem(draft.id, undoManager: undoManager)
                dismiss()
            }
        } message: {
            Text("It disappears from every week, past and future. You can undo this.")
        }
    }

    private var scheduleSection: some View {
        Section(draft.kind == .envelope ? "Budget and period" : "Amount and schedule") {
            LabeledContent(draft.kind == .envelope ? "Budget per period" : "Amount") {
                MoneyField(title: "Amount", value: $draft.amount).frame(width: 140)
            }
            LabeledContent("Repeats") {
                HStack(spacing: 6) {
                    Text("every")
                    TextField("", value: $draft.interval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: $draft.unit) {
                        Text(draft.interval == 1 ? "day" : "days").tag(RecurrenceRule.Unit.day)
                        Text(draft.interval == 1 ? "week" : "weeks").tag(RecurrenceRule.Unit.week)
                        Text(draft.interval == 1 ? "month" : "months").tag(RecurrenceRule.Unit.month)
                        Text(draft.interval == 1 ? "year" : "years").tag(RecurrenceRule.Unit.year)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Menu("Presets") {
                        Button("Weekly") { preset(.week, 1) }
                        Button("Fortnightly") { preset(.week, 2) }
                        Button("Every 4 weeks") { preset(.week, 4) }
                        Button("Monthly") { preset(.month, 1) }
                        Button("Quarterly") { preset(.month, 3) }
                        Button("Every 6 months") { preset(.month, 6) }
                        Button("Yearly") { preset(.year, 1) }
                    }
                    .fixedSize()
                }
            }
            if draft.unit == .month || draft.unit == .year {
                Toggle("Always on the last day of the month", isOn: $draft.monthEnd)
            }
            DatePicker(draft.kind == .envelope ? "A period starts on" : "Next due", selection: $draft.anchor.pickerDate, displayedComponents: .date)
            Text(previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if draft.kind != .envelope {
                Picker("On a weekend or public holiday", selection: $draft.adjustment) {
                    Text("Leave it").tag(BusinessDayAdjustment.none)
                    Text("Next business day").tag(BusinessDayAdjustment.following)
                    Text("Business day before").tag(BusinessDayAdjustment.preceding)
                }
            }
            if draft.isNew {
                Toggle("Already happening (show it in past weeks too)", isOn: $draft.alreadyRunning)
            }
            Toggle("Has an end date", isOn: $draft.hasEnd)
            if draft.hasEnd {
                DatePicker("Last date", selection: $draft.end.pickerDate, displayedComponents: .date)
            }
        }
    }

    private var historySection: some View {
        Section {
            ForEach(draft.working.segments) { segment in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(segmentDates(segment))
                        Text(segment.recurrence.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.money(segment.amount)).monospacedDigit()
                    if draft.working.segments.count > 1 {
                        Button {
                            draft.removeSegment(segment.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this change")
                    }
                }
            }
            HStack {
                DatePicker("From", selection: $changeDate.pickerDate, displayedComponents: .date)
                MoneyField(title: "New amount", value: $changeAmount)
                    .frame(width: 110)
                Button("Add change") {
                    draft.addChange(from: changeDate, amount: changeAmount)
                }
            }
        } header: {
            Text("Changes over time")
        } footer: {
            Text("For a price rise you've been told about: pick the date it starts and the new amount.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewText: String {
        guard draft.interval >= 1 else { return "" }
        let recurrence = draft.recurrence
        let today = model.today
        var dates: [LocalDate] = []
        var cursor = today
        while dates.count < 3, let next = recurrence.next(onOrAfter: cursor) {
            dates.append(next)
            cursor = next.adding(days: 1)
        }
        let list = dates.map { $0.dayMonth(includeYear: $0.year != today.year) }.joined(separator: ", ")
        return "\(recurrence.label). Next: \(list)"
    }

    private func segmentDates(_ segment: ScheduleSegment) -> String {
        let from = segment.start.dayMonth(includeYear: true)
        if let end = segment.end { return "\(from) – \(end.dayMonth(includeYear: true))" }
        return "From \(from)"
    }

    private func preset(_ unit: RecurrenceRule.Unit, _ interval: Int) {
        draft.unit = unit
        draft.interval = interval
    }
}
