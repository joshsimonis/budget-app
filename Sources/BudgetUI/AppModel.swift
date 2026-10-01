import AppKit
import BudgetCore
import Foundation
import Observation

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case cashFlow, items, income, periods, transactions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cashFlow: "Cash Flow"
        case .items: "Bills & Spending"
        case .income: "Income"
        case .periods: "Periods"
        case .transactions: "Transactions"
        }
    }

    var symbol: String {
        switch self {
        case .cashFlow: "chart.line.uptrend.xyaxis"
        case .items: "list.bullet.rectangle"
        case .income: "banknote"
        case .periods: "calendar.badge.clock"
        case .transactions: "creditcard"
        }
    }
}

/// Owns the budget document, recomputes the projection after every change, saves to disk,
/// and registers each change with the window's undo manager.
@MainActor
@Observable
final class AppModel {
    private(set) var document: BudgetDocument
    private(set) var projection: Projection
    private(set) var grid: CashFlowGrid
    private(set) var today: LocalDate
    private(set) var hasSavedDocument: Bool

    var granularity: Granularity = .week {
        didSet { rebuildGrid() }
    }
    /// First visible column per granularity; nil = around today.
    var windowStart: [Granularity: Int] = [:]
    /// How many columns fit in the grid (set by the grid view).
    var visibleColumns = 12
    var sidebar: SidebarItem? = .cashFlow
    var errorMessage: String?
    /// Set by the File menu; the Bills & Spending list opens the editor for it.
    var pendingNewItem: ItemKind?

    /// Bank data from Up (nil until the first sync).
    private(set) var bank: BankCache?
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var hasUpToken = false
    var syncNotes: [String] = []

    let store: DocumentStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored let tokenStore: TokenStore

    init(
        store: DocumentStore = DocumentStore(directory: DocumentStore.defaultDirectory()),
        document: BudgetDocument? = nil,
        tokenStore: TokenStore = .keychain
    ) {
        self.store = store
        self.tokenStore = tokenStore
        var loaded = document
        var loadError: String?
        if loaded == nil {
            do {
                loaded = try store.load()
            } catch {
                loadError = "Your saved budget couldn't be opened, so a blank one was started. Backups are in \(store.backupsDirectory.path). (\(error))"
            }
        }
        let initial = loaded ?? BudgetDocument()
        let today = initial.settings.timeZone.today()
        let projection = ProjectionEngine.run(document: initial, today: today)
        self.document = initial
        self.today = today
        self.projection = projection
        self.grid = GridBuilder.build(projection, document: initial, granularity: .week)
        // An injected document (previews, tests) hasn't been saved yet.
        self.hasSavedDocument = document == nil && loaded != nil
        self.errorMessage = loadError
        if document == nil, let data = store.read(named: AppModel.bankCacheName) {
            self.bank = try? BankCache.decode(data)
        }
        self.hasUpToken = tokenStore.read() != nil
        if bank != nil { recompute() }
        startClock()
        startSyncSchedule()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.syncNow() }
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    var showsWelcome: Bool { document.isEmpty && !hasSavedDocument }

    // MARK: Changes

    /// Applies an edit to the document as one undoable step.
    func perform(_ actionName: String, undoManager: UndoManager?, _ edit: (inout BudgetDocument) -> Void) {
        var updated = document
        edit(&updated)
        guard updated != document else { return }
        replaceDocument(with: updated, actionName: actionName, undoManager: undoManager)
    }

    private func replaceDocument(with new: BudgetDocument, actionName: String, undoManager: UndoManager?) {
        let old = document
        document = new
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.replaceDocument(with: old, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
        recompute()
        scheduleSave()
    }

    func recompute() {
        today = document.settings.timeZone.today()
        projection = ProjectionEngine.run(document: document, today: today, bank: bank)
        rebuildGrid()
    }

    /// Replaces the bank cache (after a sync or disconnect) and recomputes.
    func setBank(_ cache: BankCache?) {
        bank = cache
        recompute()
    }

    func setSyncStatus(_ status: SyncStatus) {
        syncStatus = status
    }

    func setHasUpToken(_ value: Bool) {
        hasUpToken = value
    }

    private func rebuildGrid() {
        grid = GridBuilder.build(projection, document: document, granularity: granularity)
    }

    // MARK: Grid window

    func visibleRange(columns: Int) -> Range<Int> {
        let count = grid.buckets.count
        guard count > 0 else { return 0..<0 }
        let n = max(1, min(columns, count))
        let preferred = windowStart[granularity] ?? max(0, (grid.currentBucket ?? 0) - 1)
        let start = min(max(0, preferred), count - n)
        return start..<(start + n)
    }

    func move(by columns: Int) {
        let current = visibleRange(columns: visibleColumns).lowerBound
        let maxStart = max(0, grid.buckets.count - visibleColumns)
        windowStart[granularity] = min(max(0, current + columns), maxStart)
    }

    func goToToday() {
        windowStart[granularity] = nil
    }

    /// Scrolls so `date` is roughly in the middle.
    func show(_ date: LocalDate) {
        guard let index = grid.bucketIndex(containing: date) else { return }
        windowStart[granularity] = max(0, index - visibleColumns / 2)
    }

    // MARK: Lookups

    func item(_ id: UUID?) -> BudgetItem? { id.flatMap { document.item($0) } }
    func income(_ id: UUID?) -> IncomeSource? { id.flatMap { document.income($0) } }

    // MARK: Saving

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard !showsWelcome else { return }
        do {
            try store.save(document)
            hasSavedDocument = true
        } catch {
            errorMessage = "Couldn't save your budget: \(error.localizedDescription)"
        }
    }

    /// Recomputes when the date changes (e.g. the app is left open overnight).
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                if self.document.settings.timeZone.today() != self.today {
                    self.recompute()
                }
            }
        }
    }
}
