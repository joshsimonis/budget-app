import BudgetCore
import SwiftUI

/// Regular payments and envelope budgets spotted in your Up history.
struct SuggestionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var draft: ItemDraft?

    var body: some View {
        Group {
            if model.bank == nil {
                ContentUnavailableView {
                    Label("Connect Up for suggestions", systemImage: "sparkles")
                } description: {
                    Text("Suggestions come from your last 13 months of transactions: subscriptions, bills, transfers and pay that repeat, plus what you typically spend in each category.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else if model.suggestions.isEmpty && model.envelopeSuggestions.isEmpty {
                ContentUnavailableView("Nothing new", systemImage: "checkmark.circle",
                                       description: Text("Everything regular in your history is already in your plan."))
            } else {
                List {
                    if !model.suggestions.isEmpty {
                        Section {
                            ForEach(model.suggestions) { suggestion in
                                SuggestionRow(suggestion: suggestion) {
                                    model.upsertItem(RecurringDetector.makeItem(suggestion, document: model.document), undoManager: undoManager)
                                } edit: {
                                    draft = ItemDraft(item: RecurringDetector.makeItem(suggestion, document: model.document), today: model.today, isNew: true)
                                } dismiss: {
                                    model.perform("Dismiss Suggestion", undoManager: undoManager) {
                                        $0.reconciliation.dismissedSuggestionKeys.append(suggestion.key)
                                    }
                                }
                            }
                        } header: {
                            Text("Regular payments and income")
                        } footer: {
                            Text("Adding one plans it from now on and ticks off the past ones it found.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !model.envelopeSuggestions.isEmpty {
                        Section {
                            ForEach(model.envelopeSuggestions) { suggestion in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.name).font(.headline)
                                        Text("\(suggestion.parentName.map { "\($0) · " } ?? "")\(suggestion.transactionCount) purchases in \(suggestion.weeks) weeks")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(Format.money(suggestion.weeklyAverage)) a week")
                                        .monospacedDigit()
                                    Button("Add Envelope") {
                                        model.upsertItem(RecurringDetector.makeEnvelope(suggestion, document: model.document, today: model.today), undoManager: undoManager)
                                    }
                                    Button {
                                        draft = ItemDraft(item: RecurringDetector.makeEnvelope(suggestion, document: model.document, today: model.today),
                                                          today: model.today, isNew: true)
                                    } label: {
                                        Image(systemName: "slider.horizontal.3")
                                    }
                                    .help("Edit, then add")
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            Text("Envelopes from your spending")
                        } footer: {
                            Text("Average weekly spending per Up category, for spending that isn't already in an envelope or matched to a bill.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Suggestions")
        .sheet(item: $draft) { draft in
            ItemEditorSheet(draft: draft)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: RecurringSuggestion
    let add: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.flow == .inflow ? "arrow.down.circle" : (suggestion.counterpartyUpAccountID != nil ? "arrow.left.arrow.right.circle" : "arrow.up.circle"))
                .font(.title3)
                .foregroundStyle(suggestion.flow == .inflow ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name).font(.headline)
                Text("\(suggestion.recurrence.label) · seen \(suggestion.occurrences) times · next \(suggestion.nextDate.dayMonth())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.money(suggestion.isVariable ? suggestion.latestAmount : suggestion.typicalAmount))
                    .monospacedDigit()
                    .fontWeight(.medium)
                if suggestion.isVariable {
                    Text("varies \(Format.wholeDollars(suggestion.minimumAmount))–\(Format.wholeDollars(suggestion.maximumAmount))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Add", action: add)
            Menu {
                Button("Edit, then Add…", action: edit)
                Button("Dismiss", action: dismiss)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}
