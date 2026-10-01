import Foundation

public enum DocumentCodecError: Error, Equatable, CustomStringConvertible {
    case newerVersion(Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .newerVersion(let version):
            "This budget was saved by a newer version of the app (format \(version))."
        case .unreadable(let detail):
            "The budget file couldn't be read: \(detail)"
        }
    }
}

/// JSON encoding with a schema version, so older files can be migrated when the format changes.
public enum DocumentCodec {
    private struct VersionProbe: Decodable {
        var schemaVersion: Int?
    }

    public static func encode(_ document: BudgetDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> BudgetDocument {
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).schemaVersion ?? 1
        } catch {
            throw DocumentCodecError.unreadable(String(describing: error))
        }
        guard version <= BudgetDocument.currentSchemaVersion else {
            throw DocumentCodecError.newerVersion(version)
        }
        // Future format changes migrate here, from `version` up to the current one.
        do {
            var document = try decoder.decode(BudgetDocument.self, from: data)
            document.schemaVersion = BudgetDocument.currentSchemaVersion
            return document
        } catch {
            throw DocumentCodecError.unreadable(String(describing: error))
        }
    }
}

/// Saves the budget atomically and keeps rolling backups (at most one an hour, newest 20).
public struct DocumentStore: Sendable {
    public let directory: URL
    public let fileName: String
    public var maxBackups = 20
    public var minimumBackupInterval: TimeInterval = 3600

    public init(directory: URL, fileName: String = "budget.json") {
        self.directory = directory
        self.fileName = fileName
    }

    /// ~/Library/Application Support/Budget
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Budget", isDirectory: true)
    }

    public var documentURL: URL { directory.appendingPathComponent(fileName) }
    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    /// The saved budget, or nil if there isn't one yet.
    public func load() throws -> BudgetDocument? {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return nil }
        let data = try Data(contentsOf: documentURL)
        return try DocumentCodec.decode(data)
    }

    public func save(_ document: BudgetDocument, now: Date = Date()) throws {
        let data = try DocumentCodec.encode(document)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try backupIfDue(now: now)
        try data.write(to: documentURL, options: .atomic)
    }

    /// Backups, newest first.
    public func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("budget-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func loadBackup(_ url: URL) throws -> BudgetDocument {
        try DocumentCodec.decode(Data(contentsOf: url))
    }

    /// Writes raw data (e.g. a cache) next to the budget file, atomically.
    public func write(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func read(named name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    public func delete(named name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// Copies the saved budget into Backups now, regardless of when the last backup was.
    public func backupNow(now: Date = Date()) throws {
        try backup(now: now)
    }

    private func backupIfDue(now: Date) throws {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return }
        if let newest = backups().first, let stamp = Self.timestamp(from: newest),
           now.timeIntervalSince(stamp) < minimumBackupInterval {
            return
        }
        try backup(now: now)
    }

    private func backup(now: Date) throws {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return }
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let name = "budget-\(Self.stampString(now)).json"
        let target = backupsDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: documentURL, to: target)
        }
        for old in backups().dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// "20261001-093015" in UTC (sorts chronologically).
    static func stampString(_ date: Date) -> String {
        let text = RFC3339.format(date, offsetSeconds: 0) // 2026-10-01T09:30:15+00:00
        let digits = text.prefix(19).filter { $0.isNumber }
        return String(digits.prefix(8)) + "-" + String(digits.dropFirst(8))
    }

    public static func timestamp(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent // budget-20261001-093015
        let parts = name.split(separator: "-")
        guard parts.count == 3, parts[1].count == 8, parts[2].count == 6 else { return nil }
        let d = parts[1], t = parts[2]
        let iso = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))T\(t.prefix(2)):\(t.dropFirst(2).prefix(2)):\(t.suffix(2))Z"
        return RFC3339.parse(iso)
    }
}
