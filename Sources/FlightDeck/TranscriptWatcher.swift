import Foundation

/// Tails one session's Claude transcript and reports the newest `customTitle`.
///
/// `claude` creates the transcript slightly after launch, so the watcher polls for the
/// file and only then starts reading. Reads are incremental: only bytes appended since
/// the last read are parsed. A missing file is not an error — it just means `claude`
/// isn't running, and the sidebar name stays a local label.
@MainActor
final class TranscriptWatcher {
    private let sessionID: UUID
    private let url: URL
    private let onTitle: (String) -> Void

    private var offset: UInt64 = 0
    private var timer: DispatchSourceTimer?

    init(sessionID: UUID, url: URL, onTitle: @escaping (String) -> Void) {
        self.sessionID = sessionID
        self.url = url
        self.onTitle = onTitle
    }

    deinit { timer?.cancel() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads everything appended since the last call and reports the last title found.
    /// Synchronous so tests need no expectations.
    /// Reads everything appended since the last call and reports the last title found.
    /// Synchronous so tests need no expectations.
    func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        // A shorter file means it was replaced; start over. This only detects a
        // *smaller* replacement — a same-or-larger replacement at the same path would
        // be treated as a continuation. That's acceptable here because the URL is
        // keyed to one session UUID for the watcher's whole lifetime.
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Consume only through the last complete line. A trailing partial line is left
        // unread so the next drain sees it whole — `claude` appends this file while we
        // read it, and a drain can land mid-write.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        offset += UInt64(consumed)

        let titles = String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { ClaudeSession.customTitle(inLine: String($0), sessionID: sessionID) }

        if let last = titles.last { onTitle(last) }
    }
}
