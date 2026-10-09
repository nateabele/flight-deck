import Foundation
import IntakeKit
import OSLog

/// A batch of signals from one server event, with the directory OpenCode filed it under — the
/// `?directory=` any follow-up request about it has to carry (see `OpenCodeClient`).
struct OpenCodeEventBatch: Sendable {
    let directory: String?
    let signals: [OpenCodeSignal]
}

/// The account server's `GET /global/event` stream, reconnecting until stopped.
///
/// `/global/event` rather than the per-directory `/event`: one server hosts every project the
/// account has open, and only the global stream carries all of them — each payload wrapped
/// with its `directory`.
///
/// Parsed OFF the main actor. A streaming turn emits one `message.part.delta` per token chunk;
/// those carry nothing a tab's status needs and are dropped by substring before any JSON is
/// decoded, and what survives reaches the main actor already mapped.
@MainActor
final class OpenCodeEventStream {
    private let endpoint: @MainActor () -> OpenCodeEndpoint?
    private let onBatch: @MainActor (OpenCodeEventBatch) -> Void
    private let onConnect: @MainActor () -> Void
    private let onDisconnect: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "opencode"
    )

    /// `onConnect` fires on every (re)connect, because events missed while disconnected are
    /// gone — the stream does not replay — so whoever listens has to re-read what it cares
    /// about from the server and the database.
    init(
        endpoint: @escaping @MainActor () -> OpenCodeEndpoint?,
        onBatch: @escaping @MainActor (OpenCodeEventBatch) -> Void,
        onConnect: @escaping @MainActor () -> Void = {},
        onDisconnect: @escaping @MainActor () -> Void = {}
    ) {
        self.endpoint = endpoint
        self.onBatch = onBatch
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var backoff: UInt64 = 500_000_000
            while !Task.isCancelled {
                guard let self, let endpoint = self.endpoint() else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let connected = await self.read(endpoint)
                if connected { backoff = 500_000_000 }
                if !Task.isCancelled { self.onDisconnect() }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 8_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One connection's worth of reading. Returns whether it connected at all.
    private func read(_ endpoint: OpenCodeEndpoint) async -> Bool {
        var request = URLRequest(url: endpoint.url.appendingPathComponent("global/event"))
        // The idle timeout, not a total: the server heartbeats every few seconds, so a minute
        // of silence means the connection is dead rather than quiet.
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let header = URLSessionOpenCodeHTTP.authorization(password: endpoint.password) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let deliver = onBatch
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            onConnect()
            let batches = AsyncStream<OpenCodeEventBatch> { continuation in
                let reader = Task.detached {
                    do {
                        for try await line in bytes.lines {
                            guard let batch = Self.batch(fromLine: line) else { continue }
                            continuation.yield(batch)
                        }
                    } catch {}
                    continuation.finish()
                }
                continuation.onTermination = { _ in reader.cancel() }
            }
            for await batch in batches {
                if Task.isCancelled { break }
                deliver(batch)
            }
            return true
        } catch {
            Self.logger.debug("event stream ended: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// One SSE line → a batch, or nil for anything that is not a `data:` line worth mapping.
    nonisolated static func batch(fromLine line: String, now: Date = Date()) -> OpenCodeEventBatch? {
        guard line.hasPrefix("data:") else { return nil }
        // Cheap rejects first: deltas and heartbeats are the overwhelming majority of lines.
        if line.contains("\"message.part.delta\"") || line.contains("\"server.heartbeat\"")
            || line.contains("\"message.part.updated\"") {
            return nil
        }
        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let signals = OpenCodeEventMapper.signals(inEventJSON: json, now: now)
        guard !signals.isEmpty else { return nil }
        let directory = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["directory"] as? String
        return OpenCodeEventBatch(directory: directory, signals: signals)
    }
}
