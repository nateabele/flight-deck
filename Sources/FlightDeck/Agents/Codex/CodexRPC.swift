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

    init(transport: CodexTransport) {
        self.transport = transport
        transport.onLine = { [weak self] line in self?.receive(line) }
    }

    /// Sends a request and suspends until the matching `id` comes back as a result or an
    /// error. `transportClosed()` is the only other way this resumes — nothing here can hang
    /// a caller forever on a dead app-server.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8)
        else { throw CodexRPCError.malformed(method) }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            transport.send(line + "\n")
        }
    }

    /// Fire-and-forget notification: no `id`, no reply expected.
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
