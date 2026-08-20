import Foundation

/// What a tailed file getting SHORTER than the offset we hold means.
///
/// The two answers are opposites, and picking the wrong one is silently destructive rather
/// than noisy, which is why this is a parameter and not a constant.
enum TailTruncationPolicy {
    /// The file was replaced, and the replacement is entirely ours to read. Correct for a
    /// file keyed to one conversation for its whole lifetime.
    case restartFromZero
    /// The file was compacted, and its history is NOT ours to replay. Correct for a shared
    /// append-only index, where every replayed line re-applies a value that has since moved.
    case resumeAtEnd
}

/// One look at a tailed file: how far reading got, and the complete lines it found.
///
/// Pure and `Sendable` — no actor state, no callbacks — so the read can run off the main
/// actor and only the fold back into watcher state has to return to it.
struct TailRead: Sendable {
    var offset: UInt64
    var hasChosenStart: Bool
    var lines: [String] = []
}

/// Incremental line-by-line tailing of an append-only file.
///
/// Extracted verbatim from `Scan.read`, which had carried this logic since the first
/// transcript watcher. Three things in here are load-bearing and were each learned from a
/// bug: where a first look starts reading, what a shrinking file means, and never consuming
/// a trailing line that has no newline yet.
enum TailReader {
    static func read(
        url: URL,
        offset: UInt64,
        hasChosenStart: Bool,
        truncation: TailTruncationPolicy = .restartFromZero
    ) -> TailRead {
        var result = TailRead(offset: offset, hasChosenStart: hasChosenStart)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Nothing on disk, but that settles where reading will start: a file that does
            // not exist while we are *already* watching has no history to skip, so whatever
            // appears here later is ours from byte 0.
            //
            // Deciding it here rather than on the first successful open is what makes the
            // first record in a file that springs into existence with content already in it
            // arrive. `claude` buffers its startup records and creates the transcript only
            // when it first has something to persist — for a session renamed before its
            // first turn, that is the rename itself.
            result.hasChosenStart = true
            return result
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        // The file already existed on our first look, so it predates the watcher: start
        // tailing from its current end rather than from 0. A restored session points at a
        // file that may be huge, and a codex rollout carries an ~18 KB `session_meta` header
        // before any turn happens. Neither is news.
        if !result.hasChosenStart {
            result.hasChosenStart = true
            result.offset = size
        } else if size < result.offset {
            // A file getting SHORTER than the offset we hold is the only way a replacement is
            // detectable at all: a same-size-or-larger replacement at the same path reads as
            // an ordinary continuation, indistinguishable from the original file simply having
            // grown. That gap matters more here than it used to, now that this branch carries
            // two different answers for what a shrink means.
            switch truncation {
            case .restartFromZero: result.offset = 0
            case .resumeAtEnd: result.offset = size
            }
        }
        guard size > result.offset else { return result }

        try? handle.seek(toOffset: result.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return result }

        // Consume only through the last complete line. A trailing partial line is left
        // unread so the next read sees it whole — the writer appends this file while we read
        // it, and a read can land mid-write.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return result }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        result.offset += UInt64(consumed)

        result.lines = String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        return result
    }
}
