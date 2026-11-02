import FleetKit
import Foundation
import IntakeKit
import SQLite3

/// How full a non-claude tab's context window is, read from the files its agent already writes.
/// Claude's comes from Flight Deck's status line (`UsageService`); no other agent runs one, so
/// each is read from the place its own UI takes the number from. Each parser was checked
/// against the agent's own display on 2026-11-01:
///
/// - **codex** (0.166.0): the rollout's newest `token_count` event. The TUI's "Context N% left"
///   is NOT `total / window`: codex sets aside a 12 000-token baseline (system prompt and tools)
///   and measures the rest (`TokenUsage::percent_of_context_window_remaining`). A live tab at
///   20 642 of 475 000 showed "98% left", where the plain ratio would say 4% used.
/// - **grok** (1.0.50): `signals.json` beside the session's `updates.jsonl`, rewritten after
///   every turn: `contextTokensUsed` of `contextWindowTokens`.
/// - **gemini** (agy 1.4.12): the conversation's step store. The newest `gen_metadata` row holds
///   the token count `/context` shows (field 1.9.10.1); the window is the model's input limit
///   in `executor_metadata` (field 10.1.13.2.22). `/context` on a live tab read "11.1k/1.0M
///   (1.1%)" for 11 065 and 1 048 576. Field 1.9.10.4 (256 000) is NOT the window.
/// - **opencode** (1.18.34): the newest assistant message with output, the way OpenCode's TUI
///   counts it: input + output + reasoning + cache reads and writes, over the model's
///   `limit.context` from the server's provider catalog. A model with no known limit (a local
///   ollama model answers 0) has no percentage, so no reading.
enum AgentContextReader {
    // MARK: - codex

    /// The newest `token_count` in a rollout's tail that carries `info`, or nil.
    static func codex(rolloutTail text: String) -> WireContextUsage? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let window = (info["model_context_window"] as? NSNumber)?.intValue, window > 0,
                  let last = info["last_token_usage"] as? [String: Any],
                  let tokens = (last["total_tokens"] as? NSNumber)?.intValue
            else { continue }
            let readAt = (object["timestamp"] as? String).flatMap(timestamp(_:)) ?? Date()
            return WireContextUsage(usedPercent: codexUsedPercent(tokens: tokens, window: window),
                                    windowSize: window, readAt: readAt)
        }
        return nil
    }

    static let codexBaselineTokens = 12_000

    /// 100 minus codex's own "percent left", unrounded.
    static func codexUsedPercent(tokens: Int, window: Int) -> Double {
        guard window > codexBaselineTokens else { return 100 }
        let effective = Double(window - codexBaselineTokens)
        let used = Double(max(0, tokens - codexBaselineTokens))
        return min(100, max(0, used / effective * 100))
    }

    // MARK: - grok

    static let grokSignalsName = "signals.json"

    static func grok(signals data: Data, readAt: Date) -> WireContextUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let window = (object["contextWindowTokens"] as? NSNumber)?.intValue, window > 0
        else { return nil }
        if let used = (object["contextTokensUsed"] as? NSNumber)?.doubleValue {
            return WireContextUsage(usedPercent: min(100, used / Double(window) * 100), windowSize: window, readAt: readAt)
        }
        guard let percent = (object["contextWindowUsage"] as? NSNumber)?.doubleValue else { return nil }
        return WireContextUsage(usedPercent: percent, windowSize: window, readAt: readAt)
    }

    // MARK: - gemini (agy)

    static let geminiUsedPath = [1, 9, 10, 1]
    static let geminiWindowPath = [10, 1, 13, 2, 22]

    static func gemini(generation: Data, executor: Data, readAt: Date) -> WireContextUsage? {
        guard let used = ProtoWire.uint(generation, path: geminiUsedPath),
              let window = ProtoWire.uint(executor, path: geminiWindowPath), window > 0
        else { return nil }
        return WireContextUsage(usedPercent: min(100, Double(used) / Double(window) * 100),
                                windowSize: Int(window), readAt: readAt)
    }

    /// Read-only, through `GeminiSQLite`, so a live agy store is never written.
    static func gemini(store: URL) -> WireContextUsage? {
        let newest = { (table: String) -> Data? in
            GeminiSQLite.query(store, "SELECT data FROM \(table) ORDER BY idx DESC LIMIT 1") {
                GeminiSQLite.blob($0, 0)
            }?.first
        }
        guard let generation = newest("gen_metadata"), let executor = newest("executor_metadata") else { return nil }
        // agy writes through the WAL, so the main file's date can be hours behind the row read.
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let readAt = [modified(store), modified(wal)].compactMap { $0 }.max() ?? Date()
        return gemini(generation: generation, executor: executor, readAt: readAt)
    }

    // MARK: - opencode

    struct OpenCodeTokens: Equatable, Sendable {
        let tokens: Int
        let providerID: String
        let modelID: String
        let readAt: Date
    }

    /// The newest assistant message with output, from `message.data` rows given newest first.
    static func openCodeTokens(messages: [Data]) -> OpenCodeTokens? {
        for data in messages {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["role"] as? String == "assistant",
                  let tokens = object["tokens"] as? [String: Any],
                  let output = (tokens["output"] as? NSNumber)?.intValue, output > 0,
                  let provider = object["providerID"] as? String, let model = object["modelID"] as? String
            else { continue }
            let int = { (key: String) in (tokens[key] as? NSNumber)?.intValue ?? 0 }
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            let cached = ((cache["read"] as? NSNumber)?.intValue ?? 0) + ((cache["write"] as? NSNumber)?.intValue ?? 0)
            let time = object["time"] as? [String: Any]
            let stamp = ((time?["completed"] ?? time?["created"]) as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
            return OpenCodeTokens(tokens: int("input") + output + int("reasoning") + cached,
                                  providerID: provider, modelID: model, readAt: stamp)
        }
        return nil
    }

    static func openCodeTokens(database: URL, session: String) -> OpenCodeTokens? {
        let escaped = session.replacingOccurrences(of: "'", with: "''")
        let rows = GeminiSQLite.query(
            database, "SELECT data FROM message WHERE session_id = '\(escaped)' ORDER BY time_created DESC LIMIT 50"
        ) { GeminiSQLite.blob($0, 0) ?? GeminiSQLite.text($0, 0).map { Data($0.utf8) } }
        return rows.flatMap(openCodeTokens(messages:))
    }

    /// `limit.context` of one model in `GET /config/providers`, or nil when it is unknown (0).
    static func openCodeWindow(providers body: Data, providerID: String, modelID: String) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let providers = object["providers"] as? [[String: Any]],
              let provider = providers.first(where: { $0["id"] as? String == providerID }),
              let models = provider["models"] as? [String: Any],
              let model = models[modelID] as? [String: Any],
              let limit = model["limit"] as? [String: Any],
              let context = (limit["context"] as? NSNumber)?.intValue, context > 0
        else { return nil }
        return context
    }

    static func openCode(_ tokens: OpenCodeTokens, window: Int) -> WireContextUsage {
        WireContextUsage(usedPercent: min(100, Double(tokens.tokens) / Double(window) * 100),
                         windowSize: window, readAt: tokens.readAt)
    }

    // MARK: - Files

    static func timestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
