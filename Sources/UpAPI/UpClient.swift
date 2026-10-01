import BudgetCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A small client for the parts of the Up API the budget uses.
public struct UpClient: Sendable {
    public static let host = "api.up.com.au"
    public static let baseURL = URL(string: "https://api.up.com.au/api/v1")!

    let token: String
    let transport: HTTPTransport
    let sleeper: Sleeper
    let maxRetries: Int

    public init(token: String, transport: HTTPTransport = URLSessionTransport(), sleeper: Sleeper = TaskSleeper(), maxRetries: Int = 4) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.sleeper = sleeper
        self.maxRetries = maxRetries
    }

    /// Checks the token; returns Up's id for the customer.
    public func ping() async throws -> String {
        let data = try await get(url(path: "util/ping"))
        return try decode(UpPing.self, data).meta.id
    }

    public func accounts() async throws -> [BankAccount] {
        try await list(UpAccountResource.self, first: url(path: "accounts", query: [("page[size]", "100")])).map(Self.map)
    }

    /// Every transaction created from `since` on (newest first from Up; returned oldest first).
    public func transactions(since: Date?, offsetSeconds: Int, pageSize: Int = 100) async throws -> [BankTransaction] {
        var query = [("page[size]", String(pageSize))]
        if let since {
            query.append(("filter[since]", RFC3339.format(since, offsetSeconds: offsetSeconds)))
        }
        let resources = try await list(UpTransactionResource.self, first: url(path: "transactions", query: query))
        return try resources.map(Self.map).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// One transaction, or nil if Up no longer has it.
    public func transaction(id: String) async throws -> BankTransaction? {
        do {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? id
            let data = try await get(url(path: "transactions/\(encoded)"))
            return try Self.map(decode(UpSingle<UpTransactionResource>.self, data).data)
        } catch UpError.notFound {
            return nil
        }
    }

    public func categories() async throws -> [BankCategory] {
        let data = try await get(url(path: "categories"))
        return try decode(UpList<UpCategoryResource>.self, data).data.map { resource in
            BankCategory(id: resource.id, name: resource.attributes.name, parentID: resource.relationships?.parent?.data?.id)
        }
    }

    public func tags() async throws -> [String] {
        try await list(UpTagResource.self, first: url(path: "tags", query: [("page[size]", "100")])).map(\.id)
    }

    // MARK: Requests

    static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { name, value in
            let n = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(n)=\(v)"
        }.joined(separator: "&")
    }

    func url(path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.percentEncodedQuery = Self.encodeQuery(query) }
        return components.url!
    }

    private func list<Resource: Decodable>(_ type: Resource.Type, first: URL) async throws -> [Resource] {
        var result: [Resource] = []
        var next: URL? = first
        var pages = 0
        while let current = next {
            let page = try decode(UpList<Resource>.self, try await get(current))
            result += page.data
            pages += 1
            guard let link = page.links?.next, pages < 2000 else { break }
            guard let url = URL(string: link), url.scheme == "https", url.host == Self.host else {
                throw UpError.untrustedLink(link)
            }
            next = url
        }
        return result
    }

    func get(_ url: URL) async throws -> Data {
        // The token only ever goes to the Up API.
        guard url.scheme == "https", url.host == Self.host else { throw UpError.untrustedLink(url.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as UpError {
                throw error
            } catch {
                throw UpError.transport(error.localizedDescription)
            }
            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw UpError.unauthorized
            case 404:
                throw UpError.notFound
            case 429, 500..<600:
                guard attempt < maxRetries else {
                    throw response.statusCode == 429 ? UpError.rateLimited : UpError.http(status: response.statusCode, detail: Self.detail(data))
                }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let backoff = retryAfter ?? (pow(2, Double(attempt)) + Double.random(in: 0...0.25))
                try await sleeper.sleep(seconds: min(backoff, 30))
                attempt += 1
            default:
                throw UpError.http(status: response.statusCode, detail: Self.detail(data))
            }
        }
    }

    static func detail(_ data: Data) -> String {
        if let body = try? JSONDecoder().decode(UpErrorBody.self, from: data), let first = body.errors.first {
            return first.detail ?? first.title ?? "Unknown error"
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UpError.decoding(String(describing: error))
        }
    }

    // MARK: Mapping

    static func map(_ resource: UpAccountResource) -> BankAccount {
        BankAccount(
            id: resource.id,
            name: resource.attributes.displayName,
            accountType: resource.attributes.accountType,
            ownershipType: resource.attributes.ownershipType ?? "INDIVIDUAL",
            balance: Money(cents: resource.attributes.balance.valueInBaseUnits),
            createdAt: resource.attributes.createdAt.flatMap(RFC3339.parse)
        )
    }

    static func map(_ resource: UpTransactionResource) throws -> BankTransaction {
        let a = resource.attributes
        guard let created = RFC3339.parse(a.createdAt) else {
            throw UpError.decoding("Bad createdAt \(a.createdAt) on transaction \(resource.id)")
        }
        let r = resource.relationships
        return BankTransaction(
            id: resource.id,
            accountID: r.account.data?.id ?? "",
            status: a.status == "HELD" ? .held : .settled,
            createdAt: created,
            settledAt: a.settledAt.flatMap(RFC3339.parse),
            description: a.description,
            rawText: a.rawText,
            message: a.message,
            amount: Money(cents: a.amount.valueInBaseUnits),
            roundUp: a.roundUp.map { Money(cents: $0.amount.valueInBaseUnits) },
            foreignAmount: a.foreignAmount.map { "\($0.currencyCode) \($0.value)" },
            categoryID: r.category?.data?.id,
            parentCategoryID: r.parentCategory?.data?.id,
            tagIDs: r.tags?.data.map(\.id) ?? [],
            transferAccountID: r.transferAccount?.data?.id,
            transactionType: a.transactionType,
            deepLinkURL: a.deepLinkURL
        )
    }
}
