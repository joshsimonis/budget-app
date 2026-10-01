import BudgetCore
import Foundation

public struct SyncResult: Sendable {
    public var cache: BankCache
    public var report: MergeReport
    public var fetchedCount: Int
    public var isFirstSync: Bool
}

/// Brings the local bank cache up to date with Up.
public struct UpSyncService: Sendable {
    let client: UpClient
    let timeZone: TimeZoneBridge

    public init(client: UpClient, timeZone: TimeZoneBridge) {
        self.client = client
        self.timeZone = timeZone
    }

    /// The first sync pulls `initialMonths` of history; later ones re-pull from 14 days
    /// before the last sync to catch settlements, recategorising and deletions. If anything
    /// fails, the cache passed in is left as it was.
    public func sync(_ cache: BankCache, now: Date = Date(), initialMonths: Int = 13) async throws -> SyncResult {
        var cache = cache
        let isFirst = cache.coverageStart == nil
        let windowStart: Date
        if isFirst {
            windowStart = timeZone.startOfDay(timeZone.localDate(for: now).adding(months: -initialMonths))
        } else {
            windowStart = max(cache.coverageStart ?? .distantPast, (cache.lastSync ?? now).addingTimeInterval(-14 * 86_400))
        }

        let fetched = try await client.transactions(since: windowStart, offsetSeconds: timeZone.timeZone.secondsFromGMT(for: windowStart))
        var report = TransactionMerge.apply(fetched: fetched, windowStart: windowStart, complete: true, to: &cache)

        // Held transactions older than the window may have settled or been dropped since.
        let staleHeld = cache.transactions.filter { $0.status == .held && $0.createdAt < windowStart }.prefix(25)
        for held in staleHeld {
            if let fresh = try await client.transaction(id: held.id) {
                TransactionMerge.apply(fetched: [fresh], windowStart: windowStart, complete: false, to: &cache)
            } else {
                cache.transactions.removeAll { $0.id == held.id }
                report.removed.append(held)
            }
        }

        cache.accounts = try await client.accounts()
        if cache.categories.isEmpty || (cache.categoriesFetchedAt.map { now.timeIntervalSince($0) > 7 * 86_400 } ?? true) {
            cache.categories = try await client.categories()
            cache.tags = try await client.tags()
            cache.categoriesFetchedAt = now
        }
        if isFirst { cache.coverageStart = windowStart }
        cache.lastSync = now
        return SyncResult(cache: cache, report: report, fetchedCount: fetched.count, isFirstSync: isFirst)
    }
}
