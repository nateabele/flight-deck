import Foundation
@testable import FlightDeck

/// Canned HTTP for the infra tests: answers by exact URL and records every request, so no test
/// ever reaches a real cloud or Tailscale API. An unknown URL is a 404, which fails the test
/// loudly instead of handing back an empty body that decodes as "nothing there"; `statuses`
/// makes a URL fail with a chosen status instead.
final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private let responses: [String: String]
    private let responseHeaders: [String: [String: String]]
    private let statuses: [String: Int]
    private var recorded: [Request] = []

    init(responses: [String: String] = [:], responseHeaders: [String: [String: String]] = [:],
         statuses: [String: Int] = [:]) {
        self.responses = responses
        self.responseHeaders = responseHeaders
        self.statuses = statuses
    }

    var requests: [Request] { lock.withLock { recorded } }

    func lastBody(for url: String) -> Data? {
        requests.last { $0.url == url }?.body
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, [String: String]) {
        try answer("GET", url, headers, nil)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, [String: String]) {
        try answer("POST", url, headers, body)
    }

    func delete(_ url: URL, headers: [String: String]) async throws {
        _ = try answer("DELETE", url, headers, nil)
    }

    private func answer(_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?) throws -> (Data, [String: String]) {
        let key = url.absoluteString
        lock.withLock { recorded.append(Request(method: method, url: key, headers: headers, body: body)) }
        if let status = statuses[key] { throw HTTPStatusError(status: status) }
        guard let text = responses[key] else { throw HTTPStatusError(status: 404) }
        return (Data(text.utf8), responseHeaders[key] ?? [:])
    }
}

/// The Tailscale OAuth client, held in memory: a test must never read or write the Keychain.
final class MemoryTailnetSecrets: TailnetSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var client: TailscaleOAuthClient?

    init(_ client: TailscaleOAuthClient? = nil) { self.client = client }

    func load() -> TailscaleOAuthClient? { lock.withLock { client } }
    func save(_ c: TailscaleOAuthClient) throws { lock.withLock { client = c } }
    func clear() { lock.withLock { client = nil } }
}
