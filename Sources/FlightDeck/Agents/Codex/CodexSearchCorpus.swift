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

    /// Extraction — turning a rollout line into indexable messages — is a separate change;
    /// this type only discovers which rollouts exist.
    func indexedMessages(
        inLine line: String, conversationID: String, at offset: Int
    ) -> [IndexedMessage] {
        []
    }

    /// Naming from a rollout's own content is a separate change; `indexedName`, populated at
    /// discovery from `session_index.jsonl`, is the only name this type produces today.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        .unknown
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
