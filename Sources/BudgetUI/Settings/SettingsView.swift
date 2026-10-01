import AppKit
import BudgetCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "building.columns") }
            HolidaySettingsView()
                .tabItem { Label("Holidays", systemImage: "calendar") }
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 600, height: 500)
    }
}

/// A binding into one settings value that saves through the model.
@MainActor
private func setting<Value>(_ model: AppModel, _ keyPath: WritableKeyPath<BudgetCore.Settings, Value>) -> Binding<Value> {
    Binding(
        get: { model.document.settings[keyPath: keyPath] },
        set: { value in model.updateSettings(undoManager: nil) { $0[keyPath: keyPath] = value } }
    )
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    private let zones = ["Australia/Melbourne", "Australia/Sydney", "Australia/Hobart", "Australia/Brisbane",
                         "Australia/Adelaide", "Australia/Darwin", "Australia/Perth"]

    var body: some View {
        Form {
            Picker("Time zone", selection: setting(model, \.timeZoneID)) {
                ForEach(zones, id: \.self) { zone in
                    Text(zone.replacingOccurrences(of: "Australia/", with: "")).tag(zone)
                }
            }
            Stepper("Plan \(model.document.settings.horizonMonths) months ahead", value: setting(model, \.horizonMonths), in: 3...60)
            Stepper("Show \(model.document.settings.historyWeeks) weeks back", value: setting(model, \.historyWeeks), in: 0...52)
            Stepper("Overdue items stay pending for \(model.document.settings.graceDays) days", value: setting(model, \.graceDays), in: 0...14)
            Picker("Pay days on a weekend or holiday", selection: setting(model, \.payDayAdjustment)) {
                Text("Paid the business day before").tag(BusinessDayAdjustment.preceding)
                Text("Paid the next business day").tag(BusinessDayAdjustment.following)
                Text("Paid on the day").tag(BusinessDayAdjustment.none)
            }
            Toggle("Warn when the running balance drops below", isOn: Binding(
                get: { model.document.settings.lowBalanceThreshold != nil },
                set: { on in model.updateSettings(undoManager: nil) { $0.lowBalanceThreshold = on ? .dollars(500) : nil } }
            ))
            if model.document.settings.lowBalanceThreshold != nil {
                LabeledContent("Low balance") {
                    MoneyField(title: "Amount", value: Binding(
                        get: { model.document.settings.lowBalanceThreshold ?? .zero },
                        set: { value in model.updateSettings(undoManager: nil) { $0.lowBalanceThreshold = value } }
                    ))
                    .frame(width: 120)
                }
            }
            Toggle("Include the $1,000 standard work-related deduction in tax estimates", isOn: setting(model, \.applyStandardDeduction))
        }
        .formStyle(.grouped)
    }
}

struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.document.sortedAccounts) { account in
                    AccountRow(account: account)
                }
                Button("Add Account") {
                    model.upsertAccount(Account(name: "New account"), undoManager: nil)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Items are grouped by account in the grid. The running balance adds up the accounts you count in the total.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .onSubmit { save() }
                .frame(maxWidth: 200)
            Toggle("Count in total", isOn: Binding(
                get: { account.includedInTotal },
                set: { on in
                    var updated = account
                    updated.includedInTotal = on
                    model.upsertAccount(updated, undoManager: nil)
                }
            ))
            Spacer()
            Button {
                model.deleteAccount(account.id, undoManager: nil)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { name = account.name }
        .onChange(of: name) { _, _ in save() }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != account.name else { return }
        var updated = account
        updated.name = trimmed
        model.upsertAccount(updated, undoManager: nil)
    }
}

struct HolidaySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var extraDate = LocalDate(dayNumber: 0)
    @State private var extraName = ""

    var body: some View {
        let settings = model.document.settings
        let builtIn = HolidayCalendar(region: settings.holidayRegion)
        let upcoming = builtIn.holidays(in: DateSpan(model.today, model.today.adding(days: 400)))
        Form {
            Picker("Public holidays", selection: setting(model, \.holidayRegion)) {
                Text("Victoria").tag(HolidayCalendar.Region.victoria)
                Text("None").tag(HolidayCalendar.Region.none)
            }
            Section("Coming up (untick any you don't get)") {
                ForEach(upcoming, id: \.date) { holiday in
                    Toggle(isOn: Binding(
                        get: { !settings.removedHolidays.contains(holiday.date) },
                        set: { on in
                            model.updateSettings(undoManager: nil) { s in
                                s.removedHolidays.removeAll { $0 == holiday.date }
                                if !on { s.removedHolidays.append(holiday.date) }
                            }
                        }
                    )) {
                        HStack {
                            Text(holiday.name)
                            Spacer()
                            Text(Format.date(holiday.date)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Extra days off") {
                ForEach(settings.extraHolidays, id: \.date) { holiday in
                    HStack {
                        Text(holiday.name)
                        Spacer()
                        Text(Format.date(holiday.date)).foregroundStyle(.secondary)
                        Button {
                            model.updateSettings(undoManager: nil) { $0.extraHolidays.removeAll { $0.date == holiday.date } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Name", text: $extraName, prompt: Text("e.g. AFL Grand Final Friday"))
                    DatePicker("", selection: $extraDate.pickerDate, displayedComponents: .date)
                        .labelsHidden()
                    Button("Add") {
                        let name = extraName.trimmingCharacters(in: .whitespaces)
                        model.updateSettings(undoManager: nil) { s in
                            s.extraHolidays.removeAll { $0.date == extraDate }
                            s.extraHolidays.append(Holiday(date: extraDate, name: name.isEmpty ? "Day off" : name))
                            s.extraHolidays.sort { $0.date < $1.date }
                        }
                        extraName = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { extraDate = model.today }
    }
}

struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingImport: BudgetDocument?

    var body: some View {
        Form {
            Section("Your budget file") {
                LabeledContent("Saved in") {
                    Text(model.store.directory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") {
                        model.saveNow()
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.documentURL])
                    }
                    Button("Export a Copy…") { export() }
                    Button("Import…") { importDocument() }
                }
                Text("A backup is kept each hour you make changes (the latest 20).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Backups") {
                let backups = model.store.backups()
                if backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(backups.prefix(10), id: \.self) { url in
                    HStack {
                        Text(DocumentStore.timestamp(from: url).map { stamp in
                            let date = LocalDate(chartDate: stamp)
                            return Format.date(date)
                        } ?? url.lastPathComponent)
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore…") {
                            if let document = try? model.store.loadBackup(url) { pendingImport = document }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace your current budget?", isPresented: Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
        )) {
            Button("Replace", role: .destructive) {
                if let document = pendingImport {
                    model.saveNow()
                    try? model.store.backupNow()
                    model.perform("Replace Budget", undoManager: nil) { $0 = document }
                    model.saveNow()
                }
                pendingImport = nil
            }
        } message: {
            Text("Your current budget is backed up first.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Budget export.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DocumentCodec.encode(model.document).write(to: url, options: .atomic)
        } catch {
            model.errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func importDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImport = try DocumentCodec.decode(Data(contentsOf: url))
        } catch {
            model.errorMessage = "That file isn't a budget this app can read. (\(error))"
        }
    }
}
