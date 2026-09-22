import Foundation

/// Codex's half of ⌘K.
///
/// **Why a walk and not `thread/list`.** The adapter already speaks `thread/list` with a
/// `cwd` filter and it returns exactly the fields discovery wants. It is still the wrong
/// tool: it needs a live app-server per account at backfill time, which the claude leg has
/// no equivalent of; `codexThreadListLimit` caps it at 10; and its `cwd` match is
/// exact-string with a SILENT empty result on any normalisation difference — the failure
/// `CodexAdapter.threads(inDirectory:)` calls the one most likely to make it look like it
/// simply does not work. Reading the first line of every rollout measured 0.08 s for 563
/// files and depends on nothing.
struct CodexSearchCorpus: AgentSearchCorpus {
    /// Doubles as `SearchCorpus.candidateWorkingDirectories`' worktree listing and this
    /// type's own date-tree listing — both are "what files exist at this path", so one
    /// injected seam covers both without a test needing to fake two identical closures.
    var listing: @Sendable (String) -> [String] = { SearchCorpus.defaultListing($0) }
    /// Whether an account's `sessions/` directory exists at all, so an account with none is
    /// skipped rather than walked into an empty listing.
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    func transcripts(
        forProjects projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef] {
        guard !projects.isEmpty else { return [] }
        let codexAccounts = accounts.filter { $0.agent == .codex }
        guard !codexAccounts.isEmpty else { return [] }

        // Built once, shared by every account: the candidate set is a property of the open
        // projects, not of which login is being walked. First project named wins a collision,
        // mirroring `SearchCorpus.directories`' own dedup-by-resolved-directory rule.
        var candidates: [String: (projectPath: String, workingDirectory: String)] = [:]
        for project in projects {
            for workingDirectory in SearchCorpus.candidateWorkingDirectories(
                forProjectAt: project, listing: listing
            ) {
                let key = Self.normalize(workingDirectory)
                if candidates[key] == nil {
                    candidates[key] = (project, workingDirectory)
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        return codexAccounts.flatMap { account -> [TranscriptRef] in
            let sessionsRoot = account.home.appendingPathComponent("sessions", isDirectory: true)
            guard exists(sessionsRoot.path) else { return [] }

            // Read once per account: 563 rollouts against a 95-line index here is the
            // difference between a 0.08 s walk and a pointless one.
            let indexedNames = Self.indexedNames(atHome: account.home)

            return Self.rolloutURLs(under: sessionsRoot, listing: listing).compactMap { url in
                guard let meta = Self.meta(ofRolloutAt: url),
                      let candidate = candidates[Self.normalize(meta.cwd)]
                else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return TranscriptRef(
                    url: url, projectPath: candidate.projectPath, accountHome: account.home,
                    workingDirectory: meta.cwd, conversationID: meta.id, agent: .codex,
                    provenance: meta.source, indexedName: indexedNames[meta.id], modified: modified
                )
            }
        }
    }

    /// `CodexTimelineMapper`'s own rule — prose from `event_msg`, nothing from
    /// `response_item` — applied here for a different consumer. `response_item` is the model
    /// transcript: it repeats the same prose a second time, plus a `role:"user"` record that
    /// is the assembled prompt (skills, plugin catalogue, environment context — tens of KB
    /// every turn), plus a `reasoning` record carrying an encrypted blob. Indexing it would
    /// double every reply and put instruction text into search results. `agent_reasoning`
    /// gets a timeline row elsewhere but not an index row, for the same reason
    /// `TranscriptExtractor` drops tool blocks: searching should find what somebody asked
    /// for, not everything a thought happened to mention.
    func indexedMessages(
        inLine line: String, conversationID: String, at offset: Int
    ) -> [IndexedMessage] {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Self.indexedMessages(inObject: record, conversationID: conversationID, at: offset)
    }

    /// The same rule against an already-decoded record.
    ///
    /// `CodexRolloutWatcher` decodes every line anyway to find turn boundaries
    /// (`CodexEventMapper.events(inRecord:)`); handing back the already-parsed record here is
    /// what keeps that second, expensive `JSONSerialization` pass from happening at all — the
    /// same reasoning `TranscriptExtractor.messages(inObject:)` documents for claude.
    static func indexedMessages(
        inObject record: [String: Any], conversationID: String, at offset: Int
    ) -> [IndexedMessage] {
        guard let payload = record["payload"] as? [String: Any],
              let kind = payload["type"] as? String
        else { return [] }

        let role: IndexedMessage.Role
        switch (record["type"] as? String, kind) {
        case ("event_msg", "user_message"): role = .user
        case ("event_msg", "agent_message"): role = .assistant
        default: return []
        }

        guard let text = payload["message"] as? String else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let timestamp = (record["timestamp"] as? String).flatMap(Self.timestamps.date(from:))
        return [IndexedMessage(
            conversationID: conversationID, role: role, text: trimmed, timestamp: timestamp,
            offset: offset
        )]
    }

    /// The naming rule, in order:
    ///
    /// 1. `ref.indexedName` present and not a placeholder → authoritative.
    /// 2. otherwise the first `event_msg`/`user_message` in `lines` → fallback.
    /// 3. otherwise a placeholder `indexedName` → fallback (better than a bare UUID).
    /// 4. otherwise unknown.
    ///
    /// Rule 2 outranking rule 3 is the whole point: `session_index.jsonl` mixes real renames
    /// with Flight Deck's own default tab titles ("session 206" and friends), pushed there by
    /// `thread/name/set`. Porting claude's "a rename always beats the first user message" rule
    /// literally would let those win, and ⌘K would show a placeholder for a conversation whose
    /// first line says what it is actually about.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        if let indexedName = ref.indexedName, !Self.isPlaceholderName(indexedName) {
            return .authoritative(indexedName)
        }
        if let message = Self.firstUserMessage(inLines: lines) {
            return .fallback(message)
        }
        if let indexedName = ref.indexedName {
            return .fallback(indexedName)
        }
        return .unknown
    }

    /// Shared because `ISO8601DateFormatter` is expensive to construct and this runs once per
    /// record across hundreds of thousands of records during a backfill — the same reasoning
    /// `TranscriptExtractor` documents for claude's formatter.
    ///
    /// `.withFractionalSeconds` is required, not optional: codex writes
    /// `2026-09-16T16:25:50.889Z`, and the default option set rejects the milliseconds
    /// outright rather than ignoring them — every timestamp would silently parse as nil and
    /// every hit would fall back to the transcript's mtime.
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `^session \d+$`, without a bare-slash regex literal — this project's pinned Swift 5
    /// toolchain (vendored Ghostty isn't Swift 6 clean) does not need to answer for one
    /// pattern. A prefix check plus "everything after it is only ASCII digits" rejects
    /// "session 4 retrospective" (somebody's actual title) exactly as an anchored regex would,
    /// while still catching "session 206" — Flight Deck's OWN default tab title
    /// (`SessionStore.swift`'s `"session \(sessionCounter)"`), pushed to codex by
    /// `thread/name/set`.
    private static func isPlaceholderName(_ name: String) -> Bool {
        guard name.hasPrefix("session ") else { return false }
        let remainder = name.dropFirst("session ".count)
        return !remainder.isEmpty && remainder.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Codex's only equivalent of `ConversationTitle.resolve`'s "first real user message"
    /// fallback: nothing else in a rollout says what a person actually asked for.
    private static func firstUserMessage(inLines lines: [String]) -> String? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let text = payload["message"] as? String
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Codex records the conversation's cwd in the first record, and nowhere else. There is
    /// no cheap index to consult instead: `session_index.jsonl` is rename-only (no cwd, no
    /// path) and `thread_history_1.sqlite` is a recent-turns projection — 85 turns against
    /// 563 rollouts on the machine this was measured on. The rollouts ARE the corpus.
    private static func meta(ofRolloutAt url: URL) -> (id: String, cwd: String, source: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // `session_meta`'s `base_instructions` runs to tens of KB, but `cwd` precedes it —
        // read the whole first line rather than a fixed prefix. Capped at 1 MB so a corrupt
        // file with no newline at all cannot be read forever.
        let cap = 1_000_000
        var line = Data()
        while line.count < cap {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            line.append(chunk)
            if let newline = line.firstIndex(of: 0x0A) {
                line = line[line.startIndex..<newline]
                break
            }
        }

        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["session_id"] as? String,
              let cwd = payload["cwd"] as? String
        else { return nil }
        return (id: id, cwd: cwd, source: payload["source"] as? String)
    }

    /// `<home>/sessions/YYYY/MM/DD/*.jsonl` — `archived_sessions/` is a sibling of `sessions/`
    /// and this walk never descends past `sessionsRoot`, so it is simply never reached.
    private static func rolloutURLs(
        under sessionsRoot: URL, listing: @Sendable (String) -> [String]
    ) -> [URL] {
        listing(sessionsRoot.path).flatMap { year -> [URL] in
            let yearDir = sessionsRoot.appendingPathComponent(year, isDirectory: true)
            return listing(yearDir.path).flatMap { month -> [URL] in
                let monthDir = yearDir.appendingPathComponent(month, isDirectory: true)
                return listing(monthDir.path).flatMap { day -> [URL] in
                    let dayDir = monthDir.appendingPathComponent(day, isDirectory: true)
                    return listing(dayDir.path).compactMap { name -> URL? in
                        guard name.hasSuffix(".jsonl") else { return nil }
                        return dayDir.appendingPathComponent(name)
                    }
                }
            }
        }
    }

    /// `session_index.jsonl`, keyed by conversation id. Missing or unreadable is the common
    /// case for an account that has never renamed anything, not an error.
    private static func indexedNames(atHome home: URL) -> [String: String] {
        let url = CodexNameWatcher.indexURL(forHome: home)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var names: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String
            else { continue }
            names[id] = name
        }
        return names
    }

    /// Puts a path through symlink resolution and standardisation before comparing. One
    /// helper, used on both sides of the comparison — a candidate directory and a rollout's
    /// recorded cwd — because macOS routinely differs only by a `/private` prefix, a trailing
    /// slash, or a resolved symlink, and an exact-string mismatch here is silently
    /// indistinguishable from "this project has no threads" (see
    /// `CodexAdapter.threads(inDirectory:)`).
    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
