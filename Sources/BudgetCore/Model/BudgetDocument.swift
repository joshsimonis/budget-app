import Foundation

/// Everything you've entered. Saved as one JSON file; bank data is cached separately.
public struct BudgetDocument: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var settings: Settings
    public var accounts: [Account]
    public var items: [BudgetItem]
    public var incomes: [IncomeSource]
    public var periods: [Period]
    public var checkpoints: [BalanceCheckpoint]
    public var reconciliation: ReconciliationState

    public init(
        settings: Settings = Settings(),
        accounts: [Account] = [],
        items: [BudgetItem] = [],
        incomes: [IncomeSource] = [],
        periods: [Period] = [],
        checkpoints: [BalanceCheckpoint] = [],
        reconciliation: ReconciliationState = ReconciliationState()
    ) {
        schemaVersion = BudgetDocument.currentSchemaVersion
        self.settings = settings
        self.accounts = accounts
        self.items = items
        self.incomes = incomes
        self.periods = periods
        self.checkpoints = checkpoints
        self.reconciliation = reconciliation
    }

    public static let empty = BudgetDocument()

    public var isEmpty: Bool {
        items.isEmpty && incomes.isEmpty && periods.isEmpty && checkpoints.isEmpty
    }

    public func item(_ id: UUID) -> BudgetItem? { items.first { $0.id == id } }
    public func income(_ id: UUID) -> IncomeSource? { incomes.first { $0.id == id } }
    public func period(_ id: UUID?) -> Period? { id.flatMap { id in periods.first { $0.id == id } } }
    public func account(_ id: UUID?) -> Account? { id.flatMap { id in accounts.first { $0.id == id } } }

    public func itemIndex(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    public func incomeIndex(_ id: UUID) -> Int? { incomes.firstIndex { $0.id == id } }
    public func periodIndex(_ id: UUID) -> Int? { periods.firstIndex { $0.id == id } }

    /// Name for an item or income source id.
    public func sourceName(_ id: UUID) -> String? {
        item(id)?.name ?? income(id)?.name
    }

    public var sortedAccounts: [Account] { accounts.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) } }
}
