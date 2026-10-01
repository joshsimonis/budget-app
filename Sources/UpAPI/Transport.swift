import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends HTTP requests. Swappable so tests never touch the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpError.transport("The response wasn't HTTP.")
        }
        return (data, http)
    }
}

/// Waits between retries. Swappable so tests run instantly.
public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

public enum UpError: Error, Equatable, CustomStringConvertible {
    /// The token is missing, wrong or revoked.
    case unauthorized
    case rateLimited
    case notFound
    case http(status: Int, detail: String)
    case decoding(String)
    case transport(String)
    /// A pagination link pointed somewhere other than the Up API.
    case untrustedLink(String)

    public var description: String {
        switch self {
        case .unauthorized:
            "Up didn't accept the personal access token. Check it in Settings › Up Bank, or make a new one in the Up app."
        case .rateLimited:
            "Up asked us to slow down. Try syncing again in a minute."
        case .notFound:
            "Up couldn't find that."
        case .http(let status, let detail):
            "Up returned an error (\(status)): \(detail)"
        case .decoding(let detail):
            "Couldn't read Up's response: \(detail)"
        case .transport(let detail):
            "Couldn't reach Up: \(detail)"
        case .untrustedLink(let link):
            "Ignored an unexpected link from Up: \(link)"
        }
    }
}
