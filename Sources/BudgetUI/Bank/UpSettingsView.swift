import AppKit
import BudgetCore
import SwiftUI

struct UpSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var connecting = false
    @State private var errorText: String?
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            if model.hasUpToken {
                connected
            } else {
                notConnected
            }
        }
        .formStyle(.grouped)
    }

    private var notConnected: some View {
        Section {
            Text("Connect Up to use your real balance, tick bills off as they're paid, track envelopes against what you actually spend, and get suggestions for regular payments.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Create a Personal Access Token in the Up app (Data sharing › Personal Access Token) or at api.up.com.au, then paste it here. It's kept in your Mac's Keychain and only ever sent to Up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Up's guide to getting a token", destination: URL(string: "https://api.up.com.au/getting_started")!)
            SecureField("Personal access token", text: $token, prompt: Text("up:yeah:…"))
            HStack {
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if connecting { ProgressView().controlSize(.small) }
                Button("Connect") {
                    connecting = true
                    errorText = nil
                    Task {
                        errorText = await model.connectUp(token: token)
                        connecting = false
                        if errorText == nil { token = "" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
            }
        } header: {
            Text("Up Bank")
        }
    }

    @ViewBuilder
    private var connected: some View {
        Section("Up Bank") {
            LabeledContent("Status") {
                switch model.syncStatus {
                case .idle:
                    Text(lastSyncText)
                case .syncing:
                    HStack { ProgressView().controlSize(.small); Text("Syncing…") }
                case .failed(let message):
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let bank = model.bank {
                LabeledContent("Transactions") {
                    Text("\(bank.transactions.count)" + (bank.coverageStart.map { " since \(LocalDate(chartDate: $0).dayMonth(includeYear: true))" } ?? ""))
                }
            }
            HStack {
                Button("Sync Now") { Task { await model.syncNow() } }
                    .disabled(model.syncStatus == .syncing)
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnostics(), forType: .string)
                }
                Spacer()
                Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
            }
            ForEach(model.syncNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Disconnect Up?", isPresented: $confirmDisconnect) {
            Button("Disconnect and Keep Bank Data") { model.disconnectUp(removeData: false) }
            Button("Disconnect and Delete Bank Data", role: .destructive) { model.disconnectUp(removeData: true) }
        } message: {
            Text("The token is removed from your Keychain. You can also revoke it in the Up app.")
        }

        if let bank = model.bank {
            Section {
                ForEach(bank.accounts) { upAccount in
                    UpAccountRow(upAccount: upAccount)
                }
                if let total = model.upBalance {
                    LabeledContent("Counted in your running balance") {
                        Text(Format.money(total)).monospacedDigit().fontWeight(.semibold)
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Untick savers you don't want counted (e.g. long-term savings). Moving money between counted accounts doesn't change the total.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastSyncText: String {
        guard let last = model.bank?.lastSync else { return "Not synced yet" }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        if minutes < 1 { return "Synced just now" }
        if minutes < 60 { return "Synced \(minutes) min ago" }
        return "Synced \(LocalDate(chartDate: last).dayMonth())"
    }
}

private struct UpAccountRow: View {
    @Environment(AppModel.self) private var model
    let upAccount: BankAccount

    var body: some View {
        let linked = model.document.accounts.first { $0.upAccountID == upAccount.id }
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(upAccount.name)
                Text(kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.money(upAccount.balance)).monospacedDigit()
            Toggle("Count", isOn: Binding(
                get: { linked?.includedInTotal ?? false },
                set: { on in
                    guard var account = linked else { return }
                    account.includedInTotal = on
                    model.upsertAccount(account, undoManager: nil)
                }
            ))
            .labelsHidden()
            .disabled(linked == nil)
        }
    }

    private var kind: String {
        let type = switch upAccount.accountType {
        case "TRANSACTIONAL": "Spending account"
        case "SAVER": "Saver"
        case "HOME_LOAN": "Home loan"
        default: upAccount.accountType.capitalized
        }
        return upAccount.isJoint ? "\(type) (2Up)" : type
    }
}
