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
///
/// **Agent-blind.** Every fact about a record's shape — how a line becomes an `IndexedMessage`,
/// what counts as a rename — comes from `ref.agent`'s own `AgentSearchCorpus`, resolved per
/// file. This actor only knows how to batch, commit, prune and cancel.
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

    /// How a ref's agent is turned into the parser for its transcript.
    ///
    /// Injected rather than reaching for `AgentID.searchCorpus` directly, for the reason
    /// `listing`, `exists` and `modified` are injected elsewhere in this subsystem: it is the
    /// seam that lets a test drive a second agent's transcripts through this actor without
    /// depending on which adapters happen to be searchable yet. Production always takes the
    /// default.
    private let corpus: @Sendable (AgentID) -> AgentSearchCorpus?

    init(
        index: SearchIndex,
        corpus: @escaping @Sendable (AgentID) -> AgentSearchCorpus? = { $0.searchCorpus }
    ) {
        self.index = index
        self.corpus = corpus
    }

    func build(_ refs: [TranscriptRef], progress: @Sendable (Progress) -> Void) async {
        let files = refs.sorted { $0.modified > $1.modified }

        // Before anything is added, so a project removed from the sidebar stops answering
        // immediately rather than at the end of a walk that may take a minute.
        //
        // `projects` is built from `files`, not from the caller's own project list, because
        // `prune` dooms a row on `!keepingSources.contains(source) || !projects.contains
        // (project)` — an OR, so `projects` is a second, independent kill switch rather than
        // a scope that only protects. Handing it `files.map(\.projectPath)` cannot doom
        // anything `keepingSources` was not already going to doom: every source kept by
        // `keepingSources` came from one of `files`, whose `projectPath` is by construction
        // already in this set. The newly-doomed set from this change is therefore provably
        // empty — but it also means `build([])` prunes with both sets empty, which wipes the
        // entire index. `AppDelegate`'s `refs ?? []` on a failed walk is one step from that.
        try? index.prune(
            keepingSources: Set(files.map(\.url)),
            projects: Set(files.map(\.projectPath))
        )

        for (position, ref) in files.enumerated() {
            // Checked per file rather than per line: a cancelled build should stop promptly,
            // but tearing out of the middle of a file would abandon work already parsed.
            if Task.isCancelled { return }
            index(ref)
            progress(Progress(indexed: position + 1, total: files.count))
            // Hands the thread back between files so a backfill cannot monopolise a core
            // while agents are running in the same process.
            await Task.yield()
        }
    }

    /// One transcript: everything appended since the offset the index remembers.
    private func index(_ ref: TranscriptRef) {
        // An agent that answers nil is a refusal, not a crash — a ref for an agent that
        // hasn't shipped a corpus yet (or never will) simply contributes nothing, the same
        // answer `AgentSearchCorpus?` gives everywhere else it is consulted.
        guard let corpus = corpus(ref.agent) else { return }

        let startOffset = index.readOffset(for: ref.url)
        // `hasChosenStart: true` is deliberate and is the opposite of what a live watcher
        // wants. `TailReader`'s default for a first look is to skip to the end of an
        // existing file, because a watcher attaching to a running session does not want its
        // backlog. A backfill wants exactly that backlog — it *is* the backlog.
        let read = TailReader.read(url: ref.url, offset: startOffset, hasChosenStart: true)
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
            try? index.ingest([], for: ref, offset: 0)
        }

        var batch: [IndexedMessage] = []

        // `read.lineOffsets` is `TailReader`'s own accounting of where each line starts, in
        // lockstep with `read.lines` — not reconstructed here by summing line lengths, which
        // would silently drift the moment a blank line in the tailed range is consumed but
        // (like `read.lines`) never appears in either array.
        for (line, offset) in zip(read.lines, read.lineOffsets) {
            batch += corpus.indexedMessages(
                inLine: line, conversationID: ref.conversationID, at: Int(offset)
            )

            if batch.count >= Self.batchSize {
                // `nil`: add these rows without moving the read position. The read position
                // only advances once, at the very end of this file's pass (below), so an
                // interruption between here and there re-reads these lines rather than
                // skipping them — and no intra-loop commit can be mistaken for the restart
                // handled above, because only `offset: 0` means that and `nil` never does.
                try? index.ingest(batch, for: ref, offset: nil)
                batch.removeAll(keepingCapacity: true)
            }
        }

        try? index.ingest(batch, for: ref, offset: read.offset)

        // Resolved once over the whole pass's lines, not line-by-line: a naming rule's own
        // priority — a rename beats the first user message regardless of which comes first
        // in the file — only holds within a single call. Feeding it one line at a time would
        // lose that priority the moment a rename line is followed by a later user line,
        // silently replacing a real name with the first message's text.
        //
        // The verdict, not a bare name: only `.authoritative` may overwrite, for the reason
        // `AgentSearchCorpus.conversationName` documents. `.unknown` writes nothing at all,
        // which is what stops a pass with no conversational lines in it blanking a good name.
        //
        // `setConversationName` is a `SearchIndex` protocol member, so this calls straight
        // through it rather than downcasting to `SQLiteSearchIndex` — a downcast here would
        // silently no-op against any other conformer, including an in-memory stub used by
        // other tests.
        switch corpus.conversationName(inLines: read.lines, for: ref) {
        case .authoritative(let name):
            try? index.setConversationName(
                name, projectPath: ref.projectPath, agent: ref.agent.rawValue,
                for: ref.conversationID
            )
        case .fallback(let name):
            if (try? index.conversationNames())?[ref.conversationID] == nil {
                try? index.setConversationName(
                    name, projectPath: ref.projectPath, agent: ref.agent.rawValue,
                    for: ref.conversationID
                )
            }
        case .unknown:
            break
        }
    }
}
