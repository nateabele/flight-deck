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
    func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        // A shorter file means it was replaced; start over.
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset = size

        let titles = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { ClaudeSession.customTitle(inLine: String($0), sessionID: sessionID) }

        if let last = titles.last { onTitle(last) }
    }
}
