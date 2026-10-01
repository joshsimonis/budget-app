import BudgetCore
import SwiftUI

struct PeriodsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var editing: Period?
    @State private var isNew = false

    var body: some View {
        Group {
            if model.document.periods.isEmpty {
                ContentUnavailableView {
                    Label("No periods", systemImage: "calendar.badge.clock")
                } description: {
                    Text("A period like Travel pauses the items you choose (groceries, transport…), adds its own lines, and can mark your pay as unpaid.")
                } actions: {
                    Button("Add a Period") { newPeriod() }
                }
            } else {
                List {
                    ForEach(model.document.periods.sorted { $0.span.start < $1.span.start }) { period in
                        Button {
                            isNew = false
                            editing = period
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(period.color.color).frame(width: 6, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(period.name).font(.headline)
                                    Text("\(Format.date(period.span.start)) – \(Format.date(period.span.end)) · \(period.span.dayCount) days")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    let lines = model.document.items.filter { $0.periodID == period.id }.count
                                    Text("\(period.pausedItemIDs.count) paused · \(lines) line\(lines == 1 ? "" : "s")")
                                    if !period.unpaidIncomeIDs.isEmpty {
                                        Text("Unpaid").foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.deletePeriod(period.id, undoManager: undoManager) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Periods")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newPeriod() } label: { Label("Add Period", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { period in
            PeriodEditorSheet(period: period, isNew: isNew)
        }
    }

    private func newPeriod() {
        let start = model.today.adding(days: 14)
        isNew = true
        editing = Period(name: "Travel", color: .green, span: DateSpan(start, start.adding(days: 20)))
    }
}

struct PeriodEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @State var period: Period
    let isNew: Bool
    @State private var start = LocalDate(dayNumber: 0)
    @State private var end = LocalDate(dayNumber: 0)
    @State private var lineDraft: ItemDraft?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $period.name)
                    Picker("Colour", selection: $period.color) {
                        ForEach(PeriodColor.allCases, id: \.self) { color in
                            Label(color.label, systemImage: "circle.fill").foregroundStyle(color.color).tag(color)
                        }
                    }
                    DatePicker("Starts", selection: $start.pickerDate, displayedComponents: .date)
                    DatePicker("Ends", selection: $end.pickerDate, displayedComponents: .date)
                }

                Section {
                    let pausable = model.document.items.filter { $0.periodID == nil && !$0.isOneOff && !$0.archived }
                        .sorted { $0.name < $1.name }
                    if pausable.isEmpty {
                        Text("No regular items to pause yet.").foregroundStyle(.secondary)
                    }
                    ForEach(pausable) { item in
                        Toggle(item.name, isOn: membership(item.id, in: \.pausedItemIDs))
                    }
                } header: {
                    Text("Pause during this period")
                } footer: {
                    Text("Envelopes are reduced for just the paused days.").font(.caption).foregroundStyle(.secondary)
                }

                if !model.document.incomes.isEmpty {
                    Section {
                        ForEach(model.document.incomes) { income in
                            Toggle("\(income.name) doesn't pay for these days", isOn: membership(income.id, in: \.unpaidIncomeIDs))
                        }
                    } header: {
                        Text("Unpaid")
                    }
                }

                Section {
                    if isNew {
                        Text("Save the period first, then add lines like \"Travel $400 a week\".")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.document.items.filter { $0.periodID == period.id }) { item in
                            Button {
                                lineDraft = ItemDraft(item: item, today: model.today)
                            } label: {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Text(GridBuilder.itemSubtitle(item, today: period.span.start)).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Button("Add a line…") {
                            lineDraft = ItemDraft(newKind: .bill, today: model.today, accountID: model.document.sortedAccounts.first?.id,
                                                  periodID: period.id, anchor: period.span.start)
                        }
                    }
                } header: {
                    Text("This period's own lines")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deletePeriod(period.id, undoManager: undoManager)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var result = period
                    result.span = DateSpan(start, max(start, end))
                    model.upsertPeriod(result, undoManager: undoManager)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(period.name.trimmingCharacters(in: .whitespaces).isEmpty || end < start)
            }
            .padding(14)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            start = period.span.start
            end = period.span.end
        }
        .sheet(item: $lineDraft) { draft in
            ItemEditorSheet(draft: draft)
        }
    }

    private func membership(_ id: UUID, in keyPath: WritableKeyPath<Period, [UUID]>) -> Binding<Bool> {
        Binding(
            get: { period[keyPath: keyPath].contains(id) },
            set: { on in
                if on {
                    if !period[keyPath: keyPath].contains(id) { period[keyPath: keyPath].append(id) }
                } else {
                    period[keyPath: keyPath].removeAll { $0 == id }
                }
            }
        )
    }
}
