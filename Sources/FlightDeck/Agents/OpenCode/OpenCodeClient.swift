import Foundation
import IntakeKit

/// One request to an OpenCode server, as data. A value rather than a `URLRequest` so a test can
/// assert on exactly what would have been sent — method, path, the `directory` it was routed to
/// and the body — without a socket.
struct OpenCodeRequest: Equatable, Sendable {
    var method: String
    var path: String
    var query: [String: String] = [:]
    var body: Data?
}

/// The one seam between `OpenCodeClient` and the network.
protocol OpenCodeHTTP: Sendable {
    func send(_ request: OpenCodeRequest) async throws -> (status: Int, body: Data)
}

enum OpenCodeError: Error, Equatable, LocalizedError {
    /// The server answered with a non-2xx status. `message` is OpenCode's own `data.message`
    /// when the body carries one — it is the most specific thing anyone knows about the
    /// failure ("Session not found") — else the raw body, trimmed.
    case http(status: Int, message: String)
    case malformed(String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): "OpenCode answered \(status): \(message)"
        case .malformed(let what): "OpenCode sent something unusable (\(what))."
        case .unreachable(let why): "The OpenCode server could not be reached (\(why))."
        }
    }
}

/// The OpenCode session fields Flight Deck reads. Trimmed on purpose, like `CodexThreadSummary`.
struct OpenCodeSessionInfo: Equatable, Sendable {
    let id: String
    let title: String
    let directory: String
    let parentID: String?
}

/// Typed calls over OpenCode's HTTP API, every one of them probed live against 1.18.34.
///
/// **Every call names the session's `directory`, and that is not decoration.** One `opencode
/// serve` hosts every project an account has open, as one instance per directory, and a call
/// without `?directory=` is routed to the instance for the server's OWN working directory. A
/// permission asked in project B is then simply not there: live-probed against a session in a
/// second directory, `GET /permission` without the parameter answered `[]` — silently, as if
/// nothing were pending — and the reply answered 404 `PermissionNotFoundError` while the
/// dialog stayed up. With the parameter both found it.
struct OpenCodeClient: Sendable {
    let http: OpenCodeHTTP

    /// `GET /global/health` — `{"healthy": true, "version": "1.18.34"}`. Returns the version.
    @discardableResult
    func health() async throws -> String? {
        let object = try await json(OpenCodeRequest(method: "GET", path: "/global/health"))
        return (object as? [String: Any])?["version"] as? String
    }

    /// `POST /session`. The title is sent at creation rather than set afterwards because
    /// OpenCode only auto-generates a title for a session still carrying its default one — so
    /// naming it here is also what stops OpenCode renaming a Flight Deck tab behind the user's
    /// back on its first turn.
    func createSession(
        directory: String, title: String, options: OpenCodeOptions
    ) async throws -> OpenCodeSessionInfo {
        var body: [String: Any] = ["title": title]
        if let model = options.modelReference {
            body["model"] = ["providerID": model.providerID, "id": model.modelID]
        }
        if let agent = options.agent { body["agent"] = agent }
        let object = try await json(OpenCodeRequest(
            method: "POST", path: "/session", query: ["directory": directory],
            body: try JSONSerialization.data(withJSONObject: body)
        ))
        guard let info = Self.sessionInfo(object) else {
            throw OpenCodeError.malformed("POST /session returned no session")
        }
        return info
    }

    /// `GET /session/{id}`, or nil when OpenCode says it does not exist — the one answer
    /// `rebind` needs to tell "deleted between launches" from "server trouble".
    func session(_ id: String, directory: String) async throws -> OpenCodeSessionInfo? {
        do {
            let object = try await json(OpenCodeRequest(
                method: "GET", path: "/session/\(id)", query: ["directory": directory]
            ))
            return Self.sessionInfo(object)
        } catch OpenCodeError.http(let status, _) where status == 404 {
            return nil
        }
    }

    /// Every session the server knows in `directory`, newest first as OpenCode lists them.
    func sessions(directory: String) async throws -> [OpenCodeSessionInfo] {
        let object = try await json(OpenCodeRequest(
            method: "GET", path: "/session", query: ["directory": directory]
        ))
        return (object as? [Any] ?? []).compactMap(Self.sessionInfo)
    }

    /// `GET /session/status`: the sessions in `directory` that are NOT idle, by id, with
    /// OpenCode's status kind (`busy`, `retry`). An idle session is simply absent — the probe
    /// with nothing running answered `{}`.
    func statuses(directory: String) async throws -> [String: String] {
        let object = try await json(OpenCodeRequest(
            method: "GET", path: "/session/status", query: ["directory": directory]
        ))
        var out: [String: String] = [:]
        for (id, value) in object as? [String: Any] ?? [:] {
            out[id] = (value as? [String: Any])?["type"] as? String ?? "busy"
        }
        return out
    }

    func rename(_ id: String, to title: String, directory: String) async throws {
        _ = try await json(OpenCodeRequest(
            method: "PATCH", path: "/session/\(id)", query: ["directory": directory],
            body: try JSONSerialization.data(withJSONObject: ["title": title])
        ))
    }

    /// `POST /session/{id}/prompt_async` — the per-tab text channel.
    ///
    /// Chosen over the `/tui/append-prompt` + `/tui/submit-prompt` pair, which looked like the
    /// natural fit and is not: those are broadcast to EVERY TUI attached to the server, even
    /// with `?directory=` set (live probe, two attached TUIs both received the same text). This
    /// call reaches only its session, never touches the composer — a draft the user is typing
    /// survives it — and is QUEUED when the session is mid-turn (the TUI marks it `QUEUED`),
    /// which is exactly the semantics a phone message needs.
    func prompt(_ id: String, text: String, directory: String) async throws {
        let body: [String: Any] = ["parts": [["type": "text", "text": text]]]
        _ = try await json(OpenCodeRequest(
            method: "POST", path: "/session/\(id)/prompt_async", query: ["directory": directory],
            body: try JSONSerialization.data(withJSONObject: body)
        ))
    }

    func abort(_ id: String, directory: String) async throws {
        _ = try await json(OpenCodeRequest(
            method: "POST", path: "/session/\(id)/abort", query: ["directory": directory]
        ))
    }

    /// `reply` is OpenCode's own vocabulary: `once`, `always`, `reject`. Flight Deck only ever
    /// sends `once` and `reject` — see `OpenCodePromptResponder` for why `always` is unreachable.
    func replyPermission(_ requestID: String, reply: String, directory: String) async throws {
        _ = try await json(OpenCodeRequest(
            method: "POST", path: "/permission/\(requestID)/reply", query: ["directory": directory],
            body: try JSONSerialization.data(withJSONObject: ["reply": reply])
        ))
    }

    /// One array of chosen LABELS per question, in question order — OpenCode answers a question
    /// by what the option says, not by its position, so there is no row arithmetic to get wrong.
    func replyQuestion(_ requestID: String, answers: [[String]], directory: String) async throws {
        _ = try await json(OpenCodeRequest(
            method: "POST", path: "/question/\(requestID)/reply", query: ["directory": directory],
            body: try JSONSerialization.data(withJSONObject: ["answers": answers])
        ))
    }

    func rejectQuestion(_ requestID: String, directory: String) async throws {
        _ = try await json(OpenCodeRequest(
            method: "POST", path: "/question/\(requestID)/reject", query: ["directory": directory]
        ))
    }

    /// Every pending permission and question request in `directory`, as OpenCode reports them —
    /// the same objects its `permission.asked` / `question.asked` events carry.
    func pendingRequestObjects(directory: String) async throws
        -> (permissions: [[String: Any]], questions: [[String: Any]])
    {
        let permissions = try await json(OpenCodeRequest(method: "GET", path: "/permission", query: ["directory": directory]))
        let questions = try await json(OpenCodeRequest(method: "GET", path: "/question", query: ["directory": directory]))
        return (permissions as? [[String: Any]] ?? [], questions as? [[String: Any]] ?? [])
    }

    /// The ids of every permission and question request pending in `root`'s conversation —
    /// its own, and any raised by its subagents' child sessions, which OpenCode files under the
    /// CHILD's id (see `OpenCodeSignal`). What a blind abort rejects when it has no call id.
    func pendingRequests(inTreeOf root: String, directory: String) async throws
        -> (permissions: [String], questions: [String])
    {
        func entries(_ path: String) async throws -> [(id: String, session: String)] {
            let object = try await json(OpenCodeRequest(
                method: "GET", path: path, query: ["directory": directory]
            ))
            return (object as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String, let session = entry["sessionID"] as? String
                else { return nil }
                return (id, session)
            }
        }
        let permissions = try await entries("/permission")
        let questions = try await entries("/question")
        var verdicts: [String: Bool] = [root: true]
        func belongs(_ session: String) async -> Bool {
            if let known = verdicts[session] { return known }
            // Walk up the parent chain. Bounded: subagents nest a level or two, and a cycle in
            // data from a server is not something to spin on.
            var current = session
            for _ in 0..<8 {
                guard let info = try? await self.session(current, directory: directory),
                      let parent = info.parentID
                else { break }
                if parent == root { verdicts[session] = true; return true }
                current = parent
            }
            verdicts[session] = false
            return false
        }
        var ownPermissions: [String] = []
        for entry in permissions {
            if await belongs(entry.session) { ownPermissions.append(entry.id) }
        }
        var ownQuestions: [String] = []
        for entry in questions {
            if await belongs(entry.session) { ownQuestions.append(entry.id) }
        }
        return (ownPermissions, ownQuestions)
    }

    // MARK: - Plumbing

    private func json(_ request: OpenCodeRequest) async throws -> Any? {
        let (status, body) = try await http.send(request)
        guard (200..<300).contains(status) else {
            throw OpenCodeError.http(status: status, message: Self.message(in: body))
        }
        // 204 and empty bodies are success with nothing to say — `prompt_async` answers 204.
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }

    static func message(in body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let data = object["data"] as? [String: Any], let message = data["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no detail" : text
    }

    static func sessionInfo(_ object: Any?) -> OpenCodeSessionInfo? {
        guard let object = object as? [String: Any],
              let id = object["id"] as? String, id.hasPrefix("ses_")
        else { return nil }
        return OpenCodeSessionInfo(
            id: id,
            title: object["title"] as? String ?? "",
            directory: object["directory"] as? String ?? "",
            parentID: object["parentID"] as? String
        )
    }
}

/// The real transport: plain `URLSession` against the account's server on loopback, with the
/// per-server password OpenCode checks as HTTP basic auth (user `opencode`, its default).
struct URLSessionOpenCodeHTTP: OpenCodeHTTP {
    let baseURL: URL
    let password: String?
    var timeout: TimeInterval = 10

    /// The URL a request goes to. Separate so the query encoding can be tested on its own.
    static func url(for request: OpenCodeRequest, baseURL: URL) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: false
        ) else { return nil }
        if !request.query.isEmpty {
            // Encoded by hand: `URLQueryItem` leaves `+` alone, and a server decoding the query
            // as a form reads it as a space — `/Users/me/C++` would be routed to a directory
            // that does not exist.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=")
            components.percentEncodedQuery = request.query.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&")
        }
        return components.url
    }

    func send(_ request: OpenCodeRequest) async throws -> (status: Int, body: Data) {
        guard let url = Self.url(for: request, baseURL: baseURL) else {
            throw OpenCodeError.malformed("bad URL for \(request.path)")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let header = Self.authorization(password: password) {
            urlRequest.setValue(header, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw OpenCodeError.unreachable(error.localizedDescription)
        }
    }

    static func authorization(password: String?) -> String? {
        guard let password, !password.isEmpty else { return nil }
        return "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }
}
