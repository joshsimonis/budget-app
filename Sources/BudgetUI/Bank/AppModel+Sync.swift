import AppKit
import BudgetCore
import Foundation
import UpAPI

enum SyncStatus: Equatable {
    case idle
    case syncing
    case failed(String)
}

/// Where the Up token is kept. Tests use an in-memory store.
struct TokenStore: Sendable {
    var read: @Sendable () -> String?
    var save: @Sendable (String) throws -> Void
    var delete: @Sendable () -> Void

    static let keychain = TokenStore(
        read: { KeychainStore.readToken() },
        save: { try KeychainStore.saveToken($0) },
        delete: { KeychainStore.deleteToken() }
    )

    static func memory(_ initial: String? = nil) -> TokenStore {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: String?
            init(_ value: String?) { self.value = value }
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
            func set(_ new: String?) { lock.lock(); value = new; lock.unlock() }
        }
        let box = Box(initial)
        return TokenStore(read: { box.get() }, save: { box.set($0) }, delete: { box.set(nil) })
    }
}

extension AppModel {
    static let bankCacheName = "up-cache.json"

    /// Checks the token with Up, stores it in the Keychain and runs the first sync.
    /// Returns an error message, or nil on success.
    func connectUp(token: String) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste your personal access token first." }
        do {
            _ = try await UpClient(token: trimmed).ping()
        } catch {
            return describe(error)
        }
        do {
            try tokenStore.save(trimmed)
        } catch {
            return "Couldn't save the token to your Keychain: \(error)"
        }
        setHasUpToken(true)
        await syncNow()
        return nil
    }

    func disconnectUp(removeData: Bool) {
        tokenStore.delete()
        setHasUpToken(false)
        setSyncStatus(.idle)
        if removeData {
            setBank(nil)
            store.delete(named: Self.bankCacheName)
        }
    }

    func syncNow() async {
        guard syncStatus != .syncing else { return }
        guard let token = tokenStore.read() else {
            setHasUpToken(false)
            return
        }
        setSyncStatus(.syncing)
        let service = UpSyncService(client: UpClient(token: token), timeZone: document.settings.timeZone)
        do {
            let result = try await service.sync(bank ?? .empty)
            var reconciliation = document.reconciliation
            syncNotes = LinkRepair.repair(&reconciliation, removed: result.report.removed, cache: result.cache)
            linkAccounts(result.cache.accounts, reconciliation: reconciliation)
            setBank(result.cache)
            saveBankCache()
            setSyncStatus(.idle)
        } catch {
            setSyncStatus(.failed(describe(error)))
        }
    }

    /// Makes sure every Up account has a budget account (matched by id, then by name).
    private func linkAccounts(_ upAccounts: [BankAccount], reconciliation: ReconciliationState) {
        var updated = document
        updated.reconciliation = reconciliation
        for upAccount in upAccounts where !upAccount.isHomeLoan {
            if updated.accounts.contains(where: { $0.upAccountID == upAccount.id }) { continue }
            let name = Self.cleanName(upAccount.name)
            if let index = updated.accounts.firstIndex(where: {
                $0.upAccountID == nil && Self.cleanName($0.name).localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                updated.accounts[index].upAccountID = upAccount.id
            } else {
                let next = (updated.accounts.map(\.sortIndex).max() ?? -1) + 1
                updated.accounts.append(Account(name: name, upAccountID: upAccount.id, includedInTotal: true, sortIndex: next))
            }
        }
        if updated != document {
            perform("Link Up Accounts", undoManager: nil) { $0 = updated }
        }
    }

    /// Up names can start with an emoji ("🏠 Essentials"); keep just the words for matching.
    static func cleanName(_ name: String) -> String {
        let scalars = name.unicodeScalars.drop { !CharacterSet.alphanumerics.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? name : cleaned
    }

    func saveBankCache() {
        guard let bank else { return }
        do {
            try store.write(BankCache.encode(bank), named: Self.bankCacheName)
        } catch {
            errorMessage = "Couldn't save the bank data: \(error.localizedDescription)"
        }
    }

    /// Sync shortly after launch, then every 15 minutes while the app is open.
    func startSyncSchedule() {
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self else { return }
                if self.hasUpToken { await self.syncNow() }
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    func describe(_ error: Error) -> String {
        (error as? UpError)?.description ?? error.localizedDescription
    }

    /// The Up accounts counted in the running total.
    var includedUpAccounts: [BankAccount] {
        guard let bank else { return [] }
        let included = Set(document.accounts.filter(\.includedInTotal).compactMap(\.upAccountID))
        return bank.accounts.filter { included.contains($0.id) }
    }

    /// Sum of the included Up accounts' available balances.
    var upBalance: Money? {
        let accounts = includedUpAccounts
        return accounts.isEmpty ? nil : accounts.reduce(.zero) { $0 + $1.balance }
    }

    /// Plain-text sync details to paste when reporting a problem. No balances or descriptions.
    func diagnostics() -> String {
        var lines = ["Budget sync diagnostics"]
        lines.append("Connected: \(hasUpToken ? "yes" : "no")")
        if let bank {
            lines.append("Last sync: \(bank.lastSync.map { RFC3339.format($0, offsetSeconds: 0) } ?? "never")")
            lines.append("Coverage from: \(bank.coverageStart.map { RFC3339.format($0, offsetSeconds: 0) } ?? "–")")
            lines.append("Transactions: \(bank.transactions.count) (held: \(bank.transactions.filter { $0.status == .held }.count), transfers: \(bank.transactions.filter(\.isTransfer).count), with round-ups: \(bank.transactions.filter { $0.roundUp != nil }.count))")
            lines.append("Accounts: " + bank.accounts.map { "\($0.accountType)/\($0.ownershipType)" }.joined(separator: ", "))
            lines.append("Categories: \(bank.categories.count), tags: \(bank.tags.count)")
        }
        if case .failed(let message) = syncStatus { lines.append("Last error: \(message)") }
        lines += syncNotes.map { "Note: \($0)" }
        lines += projection.warnings.map { "Warning: \($0)" }
        return lines.joined(separator: "\n")
    }
}
