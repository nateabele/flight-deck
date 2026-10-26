import Foundation
import os

/// A codex tab's peer inbox: another agent's message arrives as the result of a tool call, not
/// as a turn typed in the user's name.
///
/// **Why not a prompt.** Claude tabs receive peer messages through Claude Code's own inbox
/// (`origin.kind = "peer"`); codex has nothing like it, so the bridge used to submit each one as a
/// labelled user prompt. To codex that is indistinguishable from the user typing, and it carries
/// the user's authority. A `ReceiveMessages` call and its output, appended with
/// `thread/inject_items`, reads as data the agent fetched — the same standing a Claude peer
/// message has — and adds no user turn. A `developer` item was the other candidate and is
/// rejected: codex ranks developer instructions above the user, so peer text would outrank them.
///
/// What codex-cli 0.164.0 does with it, probed against the shared daemon with a `--remote` TUI
/// attached:
/// - **Busy**: the pair is queued and written at the next tool boundary, and that turn's next
///   model call sees it — Claude's "drains at the next tool round".
/// - **Idle**: the pair is written at once and starts nothing; `turn/start` with an EMPTY input
///   then wakes the thread to read it, with no user message in the transcript.
/// - **The TUI draws neither the call nor its output**, only what the agent does next. Flight
///   Deck's own timeline shows the message.
/// - Injected items are absent from `thread/turns/list`, so whether a busy turn saw the message
///   is read from the rollout instead: any model output after the injected output means yes.
@MainActor
struct CodexPeerInbox {
    let rpc: CodexRPC
    let thread: UUID
    let rollout: URL?

    enum Outcome: Equatable {
        case delivered
        /// The daemon does not hold this thread, so its TUI is not attached to the daemon and
        /// the message must go the keystroke way.
        case notAttached
    }

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "codex")
    /// How often a busy thread is re-read while a message waits to be seen. `thread/read`
    /// without turns is a small request; a turn can run for an hour.
    var pollInterval: Duration = .seconds(3)

    /// Puts `text` in the thread's history as a `ReceiveMessages` result and makes sure a turn
    /// reads it. The call id comes from the message id, so a retry after a crash finds the
    /// first injection in the rollout and does not repeat it.
    func deliver(id: String, text: String) async throws -> Outcome {
        let threadID = thread.uuidString.lowercased()
        guard let status = try await status(threadID) else { return .notAttached }
        let call = Self.callID(for: id)
        if !Self.recorded(call, in: rollout) { try await inject(call, text: text, threadID: threadID) }
        if status == "idle" {
            try await wake(threadID)
        } else {
            let watcher = self
            Task { @MainActor in await watcher.wakeIfUnseen(call, text: text, threadID: threadID) }
        }
        return .delivered
    }

    static func callID(for id: String) -> String {
        "call_peer_" + id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// `nil` when the daemon does not hold the thread.
    private func status(_ threadID: String) async throws -> String? {
        let read = try await rpc.request("thread/read", ["threadId": threadID], timeoutSeconds: 5)
        let type = ((read["thread"] as? [String: Any])?["status"] as? [String: Any])?["type"] as? String
        return type == "notLoaded" ? nil : type ?? "idle"
    }

    private func inject(_ call: String, text: String, threadID: String) async throws {
        _ = try await rpc.request("thread/inject_items", [
            "threadId": threadID,
            "items": [
                ["type": "function_call", "name": "ReceiveMessages", "arguments": "{}", "call_id": call],
                ["type": "function_call_output", "call_id": call, "output": text],
            ],
        ], timeoutSeconds: 10)
    }

    private func wake(_ threadID: String) async throws {
        _ = try await rpc.request("turn/start", ["threadId": threadID, "input": [] as [Any]], timeoutSeconds: 10)
    }

    /// A busy turn can end before its next model call, leaving the message unread. Once the
    /// thread is idle, anything the model produced after the injected output means it was
    /// read; otherwise one empty turn reads it, re-injecting first if codex dropped the queue.
    private func wakeIfUnseen(_ call: String, text: String, threadID: String) async {
        do {
            while let status = try await status(threadID), status != "idle" {
                try await Task.sleep(for: pollInterval)
            }
            guard !Self.answered(call, in: rollout) else { return }
            if !Self.recorded(call, in: rollout) { try await inject(call, text: text, threadID: threadID) }
            try await wake(threadID)
        } catch {
            Self.logger.error("peer follow-up failed for \(threadID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Reading the rollout

    /// The rollout's last lines. Enough for any message the follow-up is waiting on, which was
    /// injected during the turn that just ended; codex rollouts reach tens of megabytes.
    static func tail(of url: URL?, bytes: Int = 1 << 20) -> [String] {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    static func recorded(_ call: String, in url: URL?) -> Bool {
        tail(of: url).contains { $0.contains("\"function_call_output\"") && $0.contains(call) }
    }

    static func answered(_ call: String, in url: URL?) -> Bool {
        answered(call, lines: tail(of: url))
    }

    static func answered(_ call: String, lines: [String]) -> Bool {
        guard let at = lines.lastIndex(where: { $0.contains("\"function_call_output\"") && $0.contains(call) })
        else { return false }
        return lines[(at + 1)...].contains { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any] else { return false }
            switch payload["type"] as? String {
            case "message": return payload["role"] as? String == "assistant"
            // Another peer message injected after this one is not the model reading it.
            case "function_call": return payload["name"] as? String != "ReceiveMessages"
            case "reasoning", "custom_tool_call", "local_shell_call": return true
            default: return false
            }
        }
    }
}
