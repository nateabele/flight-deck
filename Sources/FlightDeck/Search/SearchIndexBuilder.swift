import Foundation

/// Reads transcript history into the index, once, without getting in anybody's way.
///
/// **The cost this manages.** Extracting ~34 MB of conversation means parsing ~684 MB of
/// JSONL, and it happens while real agents are running in the same app. So the walk is an
/// `actor` off the main actor, it yields between files, it is cancellable at every file
/// boundary, and every file's progress is committed as a byte offset before the next one
/// starts — a build killed halfway costs nothing but the file it was inside.
///
/// **Why newest first.** The conversation you want is overwhelmingly likely to be a recent
/// one, so ordering by mtime descending means search becomes useful long before the walk
/// finishes rather than at the end of it.
///
/// **Why it reuses `TailReader`.** Incremental reading of an append-only transcript is
/// already solved there, including the two rules that are easy to get wrong: never consume a
/// trailing line without its newline (the writer is appending as we read), and treat a file
/// that shrank as a replacement. Using it means a growing transcript costs only its new
/// bytes on every later pass.
actor SearchIndexBuilder {
    struct Progress: Equatable, Sendable {
        let indexed: Int
        let total: Int
    }

    /// How many messages accumulate before a commit. Per-batch rather than per-file so a
    /// single 23 MB transcript — the largest in the corpus here — cannot hold a transaction
    /// open long enough to stall the overlay's reads behind it.
    private static let batchSize = 500

    private let index: SearchIndex

    init(index: SearchIndex) { self.index = index }

    func build(_ entries: [SearchCorpus.Entry], progress: @Sendable (Progress) -> Void) async {
        let files = Self.transcripts(in: entries)

        // Before anything is added, so a project removed from the sidebar stops answering
        // immediately rather than at the end of a walk that may take a minute.
        try? index.prune(
            keepingSources: Set(files.map(\.url)),
            projects: Set(entries.map(\.projectPath))
        )

        for (position, file) in files.enumerated() {
            // Checked per file rather than per line: a cancelled build should stop promptly,
            // but tearing out of the middle of a file would abandon work already parsed.
            if Task.isCancelled { return }
            index(file)
            progress(Progress(indexed: position + 1, total: files.count))
            // Hands the thread back between files so a backfill cannot monopolise a core
            // while agents are running in the same process.
            await Task.yield()
        }
    }

    /// One transcript: everything appended since the offset the index remembers.
    private func index(_ file: Transcript) {
        let startOffset = index.readOffset(for: file.url)
        // `hasChosenStart: true` is deliberate and is the opposite of what a live watcher
        // wants. `TailReader`'s default for a first look is to skip to the end of an
        // existing file, because a watcher attaching to a running session does not want its
        // backlog. A backfill wants exactly that backlog — it *is* the backlog.
        let read = TailReader.read(url: file.url, offset: startOffset, hasChosenStart: true)
        guard !read.lines.isEmpty else { return }

        // Drop whatever this source already holds, once, before inserting anything new. Two
        // cases reach here: a source never seen before (the delete is a no-op) and one whose
        // file shrank and was therefore re-read from the top — `TailReader` resets its own
        // position on a shrink but cannot tell us directly, so a read that ended BEFORE where
        // we thought we already were is the signal. Without the second case a replaced
        // transcript's old rows would merge with its replacement instead of being superseded.
        //
        // Firing this here, once, rather than letting an intra-loop batch commit carry
        // `offset: 0` is what stops one batch deleting the batch before it: `offset: 0` means
        // "restart" to the index, so every intra-loop commit passing it would leave only the
        // last batch standing.
        if startOffset == 0 || read.offset < startOffset {
            try? index.ingest([], from: file.url, projectPath: file.projectPath, offset: 0)
        }

        var batch: [IndexedMessage] = []

        // `read.lineOffsets` is `TailReader`'s own accounting of where each line starts, in
        // lockstep with `read.lines` — not reconstructed here by summing line lengths, which
        // would silently drift the moment a blank line in the tailed range is consumed but
        // (like `read.lines`) never appears in either array.
        for (line, offset) in zip(read.lines, read.lineOffsets) {
            batch += TranscriptExtractor.messages(
                inLine: line, conversationID: file.conversationID, offset: Int(offset)
            )

            if batch.count >= Self.batchSize {
                // `nil`: add these rows without moving the read position. The read position
                // only advances once, at the very end of this file's pass (below), so an
                // interruption between here and there re-reads these lines rather than
                // skipping them — and no intra-loop commit can be mistaken for the restart
                // handled above, because only `offset: 0` means that and `nil` never does.
                try? index.ingest(batch, from: file.url, projectPath: file.projectPath, offset: nil)
                batch.removeAll(keepingCapacity: true)
            }
        }

        try? index.ingest(batch, from: file.url, projectPath: file.projectPath, offset: read.offset)

        // Resolved once over the whole pass's lines, not line-by-line: `resolve`'s own
        // priority — a rename beats the first user message regardless of which comes first
        // in the file — only holds within a single call. Feeding it one line at a time would
        // lose that priority the moment a rename line is followed by a later user line,
        // silently replacing a real name with the first message's text.
        if let name = ConversationTitle.resolve(lines: read.lines) {
            // A later pass sees only this pass's newly appended lines, not the whole file, so
            // it has no way to know an earlier pass already found a real rename. Overwriting
            // unconditionally would let a plain user message — resolved here only as a
            // fallback, since this pass's own lines contain no rename — replace a good name
            // on every later pass, with nothing to self-heal it. So a later pass may only
            // write when it actually saw a rename record, or when nothing is stored yet.
            //
            // `setConversationName` is a `SearchIndex` protocol member (Task 6 delta), so
            // this calls straight through it rather than downcasting to `SQLiteSearchIndex`
            // — a downcast here would silently no-op against any other conformer, including
            // an in-memory stub used by another task's tests.
            if Self.containsRename(read.lines)
                || (try? index.conversationNames())?[file.conversationID] == nil {
                try? index.setConversationName(
                    name, projectPath: file.projectPath, for: file.conversationID
                )
            }
        }
    }

    /// Whether any line in `lines` is a rename record `ConversationTitle.resolve` would
    /// treat as authoritative. Mirrors its own two cases, including that a bare `"type"`
    /// match with no name field is not a rename — matching what `resolve` itself requires
    /// before it lets a record override a fallback name.
    private static func containsRename(_ lines: [String]) -> Bool {
        lines.contains { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { return false }
            switch type {
            case "agent-name": return (object["agentName"] as? String) != nil
            case "custom-title": return (object["customTitle"] as? String) != nil
            default: return false
            }
        }
    }

    private struct Transcript {
        let url: URL
        let projectPath: String
        let conversationID: String
        let modified: Date
    }

    /// Every `.jsonl` under the in-scope directories, newest first.
    ///
    /// Subdirectories are skipped: `~/.claude/projects/<dir>/<conversation>/subagents/*.jsonl`
    /// holds subagent transcripts, which are not conversations anyone resumes and would
    /// double-count text their parent already carries.
    private static func transcripts(in entries: [SearchCorpus.Entry]) -> [Transcript] {
        var found: [Transcript] = []
        for entry in entries {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: entry.directory.path))
                ?? []
            for name in names where name.hasSuffix(".jsonl") {
                let url = entry.directory.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append(Transcript(
                    url: url,
                    projectPath: entry.projectPath,
                    conversationID: String(name.dropLast(".jsonl".count)),
                    modified: modified
                ))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }
}
