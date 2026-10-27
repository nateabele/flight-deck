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
        // Where this message's lines will start, so the follow-up reads from here rather than
        // from a fixed tail a long turn can scroll past.
        let offset = Self.size(of: rollout)
        if !Self.recorded(call, in: rollout) { try await inject(call, text: text, threadID: threadID) }
        if status == "idle" { try await wake(threadID) }
        let watcher = self
        Task { @MainActor in await watcher.followUp(call, text: text, threadID: threadID, from: offset, attempt: 0) }
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

    /// Whether the turn that should have read the message did, once it is over.
    ///
    /// - **Unread** — a busy turn ended before its next model call: one empty turn reads it.
    /// - **Compacted away** — codex compacted the context after the message went in and before
    ///   the model answered, and the summary dropped it. On 2026-10-27 at 04:11 UTC Execute 2 was
    ///   woken for a new assignment from The Plan; the wake turn opened with an automatic
    ///   compaction, and Execute 2 replied "Standing by for the next assignment". Model output
    ///   after a compaction is not evidence the message was read, so it is put back once, under
    ///   a new call id, and the thread woken again. Only after a compaction: a message the model
    ///   did read is never handed over twice (see the 2026-10-26 duplicates in `deliver`'s history).
    ///
    /// Reads the rollout from where it stood before the injection, never a fixed tail a long turn
    /// can scroll past.
    private func followUp(_ call: String, text: String, threadID: String, from offset: UInt64, attempt: Int) async {
        do {
            // A wake's turn can still read idle for a moment: wait for it to begin, briefly.
            var polls = 0
            while polls < 20, try await status(threadID) == "idle",
                  !Self.lines(of: rollout, from: offset).contains(where: { $0.contains("\"task_started\"") }) {
                polls += 1
                try await Task.sleep(for: pollInterval)
            }
            while let status = try await status(threadID), status != "idle" {
                try await Task.sleep(for: pollInterval)
            }
            switch Self.reading(of: call, lines: Self.lines(of: rollout, from: offset)) {
            case .read:
                return
            case .unread:
                try await wake(threadID)
            case .compactedAway:
                guard attempt == 0 else {
                    Self.logger.error("peer message \(call, privacy: .public) compacted away twice in \(threadID, privacy: .public)")
                    return
                }
                let again = call + "-r1", next = Self.size(of: rollout)
                try await inject(again, text: text, threadID: threadID)
                try await wake(threadID)
                await followUp(again, text: text, threadID: threadID, from: next, attempt: 1)
            }
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

    static func size(of url: URL?) -> UInt64 {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()) ?? 0
    }

    /// Every line written since `offset`. A line cut in half by the offset is dropped by
    /// `answered`, which reads only whole JSON records.
    static func lines(of url: URL?, from offset: UInt64) -> [String] {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).components(separatedBy: "\n")
    }

    /// Whether the injection is already in the rollout — `deliver`'s guard against a retry
    /// after a crash, which only ever follows the injection closely. Not used to decide anything
    /// about an injection a long turn may have scrolled past; see `wakeIfUnseen`.
    static func recorded(_ call: String, in url: URL?) -> Bool {
        tail(of: url).contains { $0.contains("\"function_call_output\"") && $0.contains(call) }
    }

    enum Reading: Equatable { case read, unread, compactedAway }

    static func answered(_ call: String, lines: [String]) -> Bool { reading(of: call, lines: lines) == .read }

    /// What became of the injected output in `lines`: the model answered after it, a compaction
    /// came first, or neither yet.
    static func reading(of call: String, lines: [String]) -> Reading {
        guard let at = lines.lastIndex(where: { $0.contains("\"function_call_output\"") && $0.contains(call) })
        else { return .unread }
        for line in lines[(at + 1)...] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "compacted" { return .compactedAway }
            guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "message" where payload["role"] as? String == "assistant": return .read
            // Another peer message injected after this one is not the model reading it.
            case "function_call" where payload["name"] as? String != "ReceiveMessages": return .read
            case "reasoning", "custom_tool_call", "local_shell_call": return .read
            default: continue
            }
        }
        return .unread
    }
}
