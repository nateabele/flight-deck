import Foundation

/// Byte plumbing, split from `CodexRPC` so the protocol logic is testable without a process.
@MainActor
protocol CodexTransport: AnyObject {
    func send(_ line: String)
    var onLine: ((String) -> Void)? { get set }
}

enum CodexRPCError: Error, Equatable {
    case transportClosed
    case remote(code: Int, message: String)
    case timeout
    case malformed(String)
}

/// Newline-delimited JSON-RPC 2.0 against `codex app-server`.
///
/// One object per line — NOT the Content-Length framing LSP and MCP use. Verified directly
/// against the binary; sending a length header gets no response at all. Codex also emits
/// occasional non-JSON banner lines on its stdout; those are swallowed rather than treated
/// as protocol errors, because they carry no correlatable id and aren't ours to interpret.
@MainActor
final class CodexRPC {
    private let transport: CodexTransport
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    var onNotification: ((String, [String: Any]) -> Void)?

    /// Test-only observability: how many requests are still awaiting a reply. Exists so a
    /// cancellation test can assert `request`'s `onCancel` actually removed its entry from
    /// `pending`, not merely that the caller unblocked.
    var pendingCount: Int { pending.count }

    init(transport: CodexTransport) {
        self.transport = transport
        transport.onLine = { [weak self] line in self?.receive(line) }
    }

    /// Every request still pending when this object is torn down must fail rather than hang
    /// its caller forever. `transportClosed()` covers the paths that remember to call it;
    /// this covers the one that doesn't — the last strong reference simply going away (a tab
    /// closing mid-flight, a spawn failure with no explicit teardown call). Direct access to
    /// `pending` here is legal: `deinit` has unique, non-concurrent access to `self` during
    /// teardown, so no actor hop is needed despite the class being `@MainActor`.
    deinit {
        for continuation in pending.values {
            continuation.resume(throwing: CodexRPCError.transportClosed)
        }
    }

    /// Sends a request and suspends until the matching `id` comes back as a result or an
    /// error. `transportClosed()` and deinit are the only other ways this resumes on its
    /// own — but the caller's enclosing `Task` can also be cancelled out from under it, and
    /// `withCheckedThrowingContinuation` alone does not notice that: a cancelled `Task`
    /// awaiting this would stay suspended until an actual resume, and because a suspended
    /// call retains `self`, that leaks the whole `CodexRPC` too. `withTaskCancellationHandler`
    /// fixes both — its `onCancel` closure is not actor-isolated (cancellation can be
    /// requested from any thread), so it only ever hops back via `Task { @MainActor in }`
    /// rather than touching `pending` directly. That hop is safe without an explicit lock:
    /// `pending[id] = continuation` below runs synchronously with no intervening `await`, and
    /// `MainActor` is a serial executor, so the hopped cleanup task — merely enqueued, not run
    /// inline — can only actually execute after that registration completes (or after this
    /// whole synchronous prefix runs, if cancellation raced ahead of it), never before it.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        // Kept deliberately, not a bug left in place: omitting `params` entirely when the
        // caller passes nothing is correct per JSON-RPC 2.0, which marks `params` OPTIONAL.
        // This exact line caused a real incident — `CodexProcessTransport.verifyHandshake`
        // used to call `rpc.request("initialize", [:])`, which reads as "no params to send"
        // but produced a message real codex rejected outright, because `InitializeParams`
        // requires `clientInfo`. The fix that incident needed was at the *call site* (send
        // real `clientInfo`), not here: had this line instead always sent `"params": {}` for
        // an empty dictionary, `initialize` would still have failed — just with "missing
        // field `clientInfo`" instead of "missing field `params`". Omitted-vs-empty was never
        // the defect; a call site asking for something that needs specific content while
        // handing over nothing was. See the task-10a report for the full incident.
        if !params.isEmpty { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8)
        else { throw CodexRPCError.malformed(method) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                transport.send(line + "\n")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failPending(id, with: CancellationError())
            }
        }
    }

    /// Resumes and removes one pending request. Shared by `request`'s cancellation path;
    /// `transportClosed()` keeps its own loop since it must fail every entry at once.
    private func failPending(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Fire-and-forget notification: no `id`, no reply expected.
    ///
    /// Same omit-empty rule as `request` (see its comment above), and easier to fall into
    /// here: the default `= [:]` makes calling this with no params the path of least
    /// resistance, for whichever method eventually needs one that requires specific content.
    func notify(_ method: String, _ params: [String: Any] = [:]) {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else { return }
        transport.send(line + "\n")
    }

    /// Every in-flight request fails rather than hanging. A tab waiting forever on a dead
    /// app-server is indistinguishable from a hung agent, which is the worst failure mode
    /// this component can have.
    func transportClosed() {
        for continuation in pending.values {
            continuation.resume(throwing: CodexRPCError.transportClosed)
        }
        pending.removeAll()
    }

    private func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return }   // codex emits non-JSON banners; they are not errors

        if let id = obj["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = obj["error"] as? [String: Any] {
                continuation.resume(throwing: CodexRPCError.remote(
                    code: error["code"] as? Int ?? 0,
                    message: error["message"] as? String ?? "unknown"
                ))
            } else {
                continuation.resume(returning: obj["result"] as? [String: Any] ?? [:])
            }
            return
        }

        if let method = obj["method"] as? String, obj["id"] == nil {
            onNotification?(method, obj["params"] as? [String: Any] ?? [:])
        }
    }
}
