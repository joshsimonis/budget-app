import BudgetCore
import SwiftUI

struct ItemsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<UUID>()
    @State private var draft: ItemDraft?
    @State private var search = ""

    var body: some View {
        let items = filteredItems
        Group {
            if model.document.items.isEmpty {
                ContentUnavailableView {
                    Label("No bills or spending yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Add rent, subscriptions, envelopes like groceries, and one-offs.")
                } actions: {
                    Button("Add a Bill") { newItem(.bill) }
                    Button("Add an Envelope") { newItem(.envelope) }
                }
            } else {
                Table(items, selection: $selection) {
                    TableColumn("Name") { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                            if let period = model.document.period(item.periodID) {
                                Text("During \(period.name)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Type") { item in
                        Text(ItemKind.of(item).shortLabel)
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Account") { item in
                        Text(model.document.account(item.accountID)?.name ?? "–")
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Schedule") { item in
                        Text(GridBuilder.itemSubtitle(item, today: model.today))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Next") { item in
                        Text(nextDate(item).map { $0.dayMonth(includeYear: $0.year != model.today.year) } ?? "–")
                    }
                    .width(min: 70, ideal: 90)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Button("Duplicate") { duplicate(id) }
                        Divider()
                    }
                    Button("Delete", role: .destructive) {
                        for id in ids { model.deleteItem(id, undoManager: undoManager) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .searchable(text: $search, placement: .toolbar)
            }
        }
        .navigationTitle("Bills & Spending")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ItemKind.allCases) { kind in
                        Button(kind.label) { newItem(kind) }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $draft) { draft in
            ItemEditorSheet(draft: draft)
        }
        .onAppear(perform: openPendingItem)
        .onChange(of: model.pendingNewItem) { _, _ in openPendingItem() }
    }

    private func openPendingItem() {
        guard let kind = model.pendingNewItem else { return }
        model.pendingNewItem = nil
        newItem(kind)
    }

    private var filteredItems: [BudgetItem] {
        let all = model.document.items.filter { !$0.archived }.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func nextDate(_ item: BudgetItem) -> LocalDate? {
        model.projection.flows.first { $0.key.sourceID == item.id && $0.date >= model.today && $0.state == .planned }?.date
            ?? model.projection.envelopes.first { $0.itemID == item.id && $0.span.end >= model.today }?.span.start
    }

    private func newItem(_ kind: ItemKind) {
        draft = ItemDraft(newKind: kind, today: model.today, accountID: model.document.sortedAccounts.first?.id)
    }

    private func edit(_ id: UUID) {
        guard let item = model.document.item(id) else { return }
        draft = ItemDraft(item: item, today: model.today)
    }

    private func duplicate(_ id: UUID) {
        guard var item = model.document.item(id) else { return }
        item.id = UUID()
        item.name += " copy"
        item.segments = item.segments.map { segment in
            var copy = segment
            copy.id = UUID()
            return copy
        }
        model.upsertItem(item, undoManager: undoManager)
    }
}
