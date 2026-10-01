import BudgetCore
import Foundation
import Testing
@testable import UpAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned responses and records requests. Synthetic data only.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private(set) var requests: [URLRequest] = []

    /// `key` is the URL path plus query (e.g. "/api/v1/accounts?page%5Bsize%5D=100").
    func on(_ key: String, _ reply: Reply...) {
        lock.lock()
        replies[key, default: []] += reply
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        respond(to: request)
    }

    private func respond(to request: URLRequest) -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let url = request.url!
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        guard var queue = replies[key], !queue.isEmpty else {
            return (Data(#"{"errors":[{"status":"404","title":"Not Found","detail":"no fixture for \#(key)"}]}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let reply = queue.count > 1 ? queue.removeFirst() : queue[0]
        replies[key] = queue
        return (Data(reply.body.utf8), HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}

final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sleeps: [Double] = []

    func sleep(seconds: Double) async throws {
        record(seconds)
    }

    private func record(_ seconds: Double) {
        lock.lock()
        sleeps.append(seconds)
        lock.unlock()
    }
}

enum Fixtures {
    static func transaction(
        id: String, account: String = "acc-spending", status: String = "SETTLED", description: String,
        cents: Int64, created: String, roundUp: Int64? = nil, category: String? = nil, transferTo: String? = nil
    ) -> String {
        let value = String(format: "%.2f", Double(cents) / 100)
        let round = roundUp.map { #"{"amount":{"currencyCode":"AUD","value":"\#(String(format: "%.2f", Double($0) / 100))","valueInBaseUnits":\#($0)},"boostPortion":null}"# } ?? "null"
        let categoryJSON = category.map { #"{"data":{"type":"categories","id":"\#($0)"},"links":{"related":"x"}}"# } ?? #"{"data":null}"#
        let transfer = transferTo.map { #"{"data":{"type":"accounts","id":"\#($0)"}}"# } ?? #"{"data":null}"#
        return """
        {"type":"transactions","id":"\(id)","attributes":{"status":"\(status)","rawText":"\(description.uppercased()) MELBOURNE","description":"\(description)","message":null,"isCategorizable":true,"holdInfo":null,"roundUp":\(round),"cashback":null,"amount":{"currencyCode":"AUD","value":"\(value)","valueInBaseUnits":\(cents)},"foreignAmount":null,"cardPurchaseMethod":null,"settledAt":null,"createdAt":"\(created)","transactionType":null,"note":null,"performingCustomer":{"displayName":"Sam"},"deepLinkURL":"up://transaction/\(id)","someNewField":42},"relationships":{"account":{"data":{"type":"accounts","id":"\(account)"}},"transferAccount":\(transfer),"category":\(categoryJSON),"parentCategory":{"data":null},"tags":{"data":[{"type":"tags","id":"Weekly"}]},"attachment":{"data":null}}}
        """
    }

    static func page(_ items: [String], next: String? = nil) -> String {
        let link = next.map { "\"\($0)\"" } ?? "null"
        return #"{"data":[\#(items.joined(separator: ","))],"links":{"prev":null,"next":\#(link)}}"#
    }

    static let accounts = """
    {"data":[
     {"type":"accounts","id":"acc-spending","attributes":{"displayName":"Spending","accountType":"TRANSACTIONAL","ownershipType":"INDIVIDUAL","balance":{"currencyCode":"AUD","value":"1234.56","valueInBaseUnits":123456},"createdAt":"2024-08-06T12:18:29+10:00"}},
     {"type":"accounts","id":"acc-bills","attributes":{"displayName":"Bills","accountType":"SAVER","ownershipType":"INDIVIDUAL","balance":{"currencyCode":"AUD","value":"800.00","valueInBaseUnits":80000},"createdAt":"2024-08-06T12:18:29+10:00"}}
    ],"links":{"prev":null,"next":null}}
    """

    static let categories = """
    {"data":[
     {"type":"categories","id":"home","attributes":{"name":"Home"},"relationships":{"parent":{"data":null},"children":{"data":[{"type":"categories","id":"groceries"}]}}},
     {"type":"categories","id":"groceries","attributes":{"name":"Groceries"},"relationships":{"parent":{"data":{"type":"categories","id":"home"}},"children":{"data":[]}}}
    ]}
    """
}

@Suite struct UpClientTests {
    @Test func queryStringEncodesPlusAndBrackets() throws {
        let since = try #require(RFC3339.parse("2025-09-01T00:00:00+10:00"))
        let client = UpClient(token: "test")
        let url = client.url(path: "transactions", query: [("page[size]", "100"), ("filter[since]", RFC3339.format(since, offsetSeconds: 36_000))])
        #expect(url.absoluteString == "https://api.up.com.au/api/v1/transactions?page%5Bsize%5D=100&filter%5Bsince%5D=2025-09-01T00%3A00%3A00%2B10%3A00")
    }

    @Test func followsPaginationAndMapsTransactions() async throws {
        let transport = FakeTransport()
        let first = "/api/v1/transactions?page%5Bsize%5D=2&filter%5Bsince%5D=2026-09-01T00%3A00%3A00%2B10%3A00"
        transport.on(first, .init(status: 200, body: Fixtures.page([
            Fixtures.transaction(id: "t3", description: "Coffee Place", cents: -550, created: "2026-09-03T08:00:00+10:00", roundUp: -50),
            Fixtures.transaction(id: "t2", description: "Grocer", cents: -8_234, created: "2026-09-02T18:00:00+10:00", category: "groceries"),
        ], next: "https://api.up.com.au/api/v1/transactions?page%5Bafter%5D=abc&page%5Bsize%5D=2")))
        transport.on("/api/v1/transactions?page%5Bafter%5D=abc&page%5Bsize%5D=2", .init(status: 200, body: Fixtures.page([
            Fixtures.transaction(id: "t1", description: "Transfer to Bills", cents: -20_000, created: "2026-09-01T09:00:00+10:00", transferTo: "acc-bills"),
        ])))
        let client = UpClient(token: " up:yeah:test ", transport: transport)
        let since = try #require(RFC3339.parse("2026-09-01T00:00:00+10:00"))
        let transactions = try await client.transactions(since: since, offsetSeconds: 36_000, pageSize: 2)
        #expect(transactions.map(\.id) == ["t1", "t2", "t3"])
        #expect(transactions[0].transferAccountID == "acc-bills")
        #expect(transactions[1].categoryID == "groceries")
        #expect(transactions[1].amount == Money(cents: -8_234))
        #expect(transactions[2].roundUp == Money(cents: -50))
        #expect(transactions[2].balanceDelta == Money(cents: -600))
        #expect(transactions[2].tagIDs == ["Weekly"])
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer up:yeah:test" })
    }

    @Test func refusesToFollowLinksOffUp() async {
        let transport = FakeTransport()
        transport.on("/api/v1/accounts?page%5Bsize%5D=100", .init(status: 200, body: #"{"data":[],"links":{"next":"https://evil.example.com/steal"}}"#))
        let client = UpClient(token: "t", transport: transport)
        await #expect(throws: UpError.untrustedLink("https://evil.example.com/steal")) {
            _ = try await client.accounts()
        }
    }

    @Test func accountsAndCategories() async throws {
        let transport = FakeTransport()
        transport.on("/api/v1/accounts?page%5Bsize%5D=100", .init(status: 200, body: Fixtures.accounts))
        transport.on("/api/v1/categories", .init(status: 200, body: Fixtures.categories))
        let client = UpClient(token: "t", transport: transport)
        let accounts = try await client.accounts()
        #expect(accounts.map(\.name) == ["Spending", "Bills"])
        #expect(accounts[0].balance == Money(cents: 123_456))
        #expect(accounts[1].isSaver)
        let categories = try await client.categories()
        #expect(categories.first { $0.id == "groceries" }?.parentID == "home")
    }

    @Test func unauthorizedAndNotFound() async throws {
        let transport = FakeTransport()
        transport.on("/api/v1/util/ping", .init(status: 401, body: #"{"errors":[{"status":"401","title":"Not Authorized","detail":"The request was not authenticated."}]}"#))
        let client = UpClient(token: "bad", transport: transport)
        await #expect(throws: UpError.unauthorized) { _ = try await client.ping() }
        #expect(try await client.transaction(id: "missing") == nil)
    }

    @Test func backsOffWhenRateLimited() async throws {
        let transport = FakeTransport()
        transport.on("/api/v1/util/ping",
                     .init(status: 429, body: "{}", headers: ["Retry-After": "3"]),
                     .init(status: 503, body: "{}"),
                     .init(status: 200, body: #"{"meta":{"id":"customer-1","statusEmoji":"⚡️"}}"#))
        let sleeper = RecordingSleeper()
        let client = UpClient(token: "t", transport: transport, sleeper: sleeper)
        #expect(try await client.ping() == "customer-1")
        #expect(sleeper.sleeps.count == 2)
        #expect(sleeper.sleeps[0] == 3)

        let always = FakeTransport()
        always.on("/api/v1/util/ping", .init(status: 429, body: "{}"))
        let impatient = UpClient(token: "t", transport: always, sleeper: RecordingSleeper(), maxRetries: 2)
        await #expect(throws: UpError.rateLimited) { _ = try await impatient.ping() }
    }

    @Test func httpErrorsCarryUpsDetail() async {
        let transport = FakeTransport()
        transport.on("/api/v1/util/ping", .init(status: 400, body: #"{"errors":[{"status":"400","title":"Invalid","detail":"filter[since] is invalid"}]}"#))
        let client = UpClient(token: "t", transport: transport)
        await #expect(throws: UpError.http(status: 400, detail: "filter[since] is invalid")) { _ = try await client.ping() }
    }
}

@Suite struct UpSyncTests {
    let melbourne = TimeZoneBridge(identifier: "Australia/Melbourne")

    private func transactionsKey(since: String) -> String {
        "/api/v1/transactions?page%5Bsize%5D=100&filter%5Bsince%5D=" + since
            .replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "+", with: "%2B")
    }

    @Test func firstSyncThenIncrementalWithDeletionAndSettlement() async throws {
        let transport = FakeTransport()
        transport.on("/api/v1/accounts?page%5Bsize%5D=100", .init(status: 200, body: Fixtures.accounts))
        transport.on("/api/v1/categories", .init(status: 200, body: Fixtures.categories))
        transport.on("/api/v1/tags?page%5Bsize%5D=100", .init(status: 200, body: #"{"data":[{"type":"tags","id":"Weekly"}],"links":{"next":null}}"#))

        // First sync: 13 months before 1 Oct 2026 → from 1 Sep 2025 (AEST, +10:00).
        transport.on(transactionsKey(since: "2025-09-01T00:00:00+10:00"), .init(status: 200, body: Fixtures.page([
            Fixtures.transaction(id: "held-1", status: "HELD", description: "Fuel", cents: -6_000, created: "2026-09-29T10:00:00+10:00"),
            Fixtures.transaction(id: "old-held", status: "HELD", description: "Hotel", cents: -20_000, created: "2026-09-10T10:00:00+10:00"),
            Fixtures.transaction(id: "rent-1", description: "Rent", cents: -200_000, created: "2026-09-01T09:00:00+10:00"),
        ])))
        let service = UpSyncService(client: UpClient(token: "t", transport: transport), timeZone: melbourne)
        let now = try #require(RFC3339.parse("2026-10-01T09:00:00+10:00"))
        let first = try await service.sync(.empty, now: now)
        #expect(first.isFirstSync)
        #expect(first.cache.transactions.map(\.id) == ["rent-1", "old-held", "held-1"])
        #expect(first.cache.accounts.count == 2)
        #expect(first.cache.coverageStart == RFC3339.parse("2025-09-01T00:00:00+10:00"))
        #expect(first.cache.categories.count == 2)

        // A day later: window starts 14 days before the last sync (17 Sep, 09:00 AEST).
        // held-1 settled with a new amount; nothing else in the window came back.
        let later = now.addingTimeInterval(86_400)
        transport.on(transactionsKey(since: "2026-09-17T09:00:00+10:00"), .init(status: 200, body: Fixtures.page([
            Fixtures.transaction(id: "held-1", status: "SETTLED", description: "Fuel", cents: -6_150, created: "2026-09-29T10:00:00+10:00"),
        ])))
        // old-held (before the window) is checked by id and is gone.
        let second = try await service.sync(first.cache, now: later)
        #expect(!second.isFirstSync)
        #expect(second.cache.transaction("held-1")?.status == .settled)
        #expect(second.cache.transaction("held-1")?.amount == Money(cents: -6_150))
        #expect(second.cache.transaction("old-held") == nil)
        #expect(second.report.removed.map(\.id) == ["old-held"])
        #expect(second.cache.transaction("rent-1") != nil) // before the window: kept
        #expect(second.cache.lastSync == later)
    }

    @Test func failedSyncLeavesTheCacheAlone() async throws {
        let transport = FakeTransport()
        transport.on(transactionsKey(since: "2025-09-01T00:00:00+10:00"), .init(status: 401, body: "{}"))
        let service = UpSyncService(client: UpClient(token: "t", transport: transport), timeZone: melbourne)
        let now = try #require(RFC3339.parse("2026-10-01T09:00:00+10:00"))
        await #expect(throws: UpError.unauthorized) { _ = try await service.sync(.empty, now: now) }
    }
}
