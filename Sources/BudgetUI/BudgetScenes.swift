import AppKit
import BudgetCore
import SwiftUI

/// All of the app's scenes. `BudgetApp` (the executable) only hosts these.
public struct BudgetScenes: Scene {
    @State private var model = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Budget", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            BudgetCommands(model: model)
        }

        Window("Pay Calculator", id: "pay-calculator") {
            PayCalculatorView()
        }
        .defaultSize(width: 980, height: 620)

        SwiftUI.Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Makes the app behave like a normal Dock app even when it is launched as a bare
/// executable from Xcode or `swift run` (no .app bundle around it).
public final class BudgetAppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct BudgetCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Bill…") { newItem(.bill) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Envelope…") { newItem(.envelope) }
            Button("New One-off…") { newItem(.oneOff) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .windowArrangement) {
            Button("Pay Calculator") { openWindow(id: "pay-calculator") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Sync with Up") { Task { await model.syncNow() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.hasUpToken)
        }
        CommandMenu("Go") {
            Button("Today") { model.goToToday() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Back") { model.move(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { model.move(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Page") { model.move(by: -model.visibleColumns) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Next Page") { model.move(by: model.visibleColumns) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Divider()
            Button("By Day") { model.granularity = .day }
                .keyboardShortcut("1", modifiers: .command)
            Button("By Week") { model.granularity = .week }
                .keyboardShortcut("2", modifiers: .command)
            Button("By Month") { model.granularity = .month }
                .keyboardShortcut("3", modifiers: .command)
        }
    }

    private func newItem(_ kind: ItemKind) {
        model.sidebar = .items
        model.pendingNewItem = kind
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.sidebar) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            if model.showsWelcome {
                WelcomeView()
            } else {
                switch model.sidebar ?? .cashFlow {
                case .cashFlow: CashFlowView()
                case .items: ItemsListView()
                case .income: IncomeListView()
                case .periods: PeriodsListView()
                case .transactions: TransactionsView()
                }
            }
        }
        .sheet(item: $model.presentedItemDraft) { draft in
            ItemEditorSheet(draft: draft)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var balance = Money.zero

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Welcome to Budget")
                .font(.largeTitle.bold())
            Text("Plan bills, envelopes, one-offs and pay, and see your running cash total by day, week or month.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Start with today's balance")
                        .font(.headline)
                    HStack {
                        MoneyField(title: "Balance", value: $balance)
                            .frame(width: 180)
                        Button("Start") {
                            model.startBlank(balance: balance, undoManager: undoManager)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    Text("Use the total of the accounts you budget from. You can connect Up Bank later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 480)
            Button("Or explore a sample budget first") {
                model.loadSample(undoManager: undoManager)
            }
            .buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
