import Foundation

/// Claude's half of ⌘K: `~/.claude/projects/<encoded-cwd>/<conversation>.jsonl`.
///
/// Per-account, unlike the code this replaces. A second login is a second `CLAUDE_CONFIG_DIR`
/// with its own `projects/` tree, and reading one hardcoded root is what made ⌘K blind to
/// every conversation under a non-default account.
struct ClaudeSearchCorpus: AgentSearchCorpus {
    /// Doubles as `SearchCorpus.candidateWorkingDirectories`' worktree listing and this
    /// type's own directory listing — both are "what files exist at this path", so one
    /// injected seam covers both without a test needing to fake two identical closures.
    var listing: @Sendable (String) -> [String] = { SearchCorpus.defaultListing($0) }
    /// Passed straight through to `SearchCorpus.directories`, which is where
    /// `SearchCorpusTests` drives it with fakes to assert which candidate directories are
    /// rejected; this type's own default reaches the real filesystem.
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    func transcripts(
        forProjects projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef] {
        // `SearchCorpus.directories` is the one implementation of "which encoded directories
        // belong to these projects" — its exact-match-not-prefix and dedup-by-resolved-
        // directory rules are exactly the ones this walk needs too, and are guarded by
        // `SearchCorpusTests`. A second, hand-rolled copy here would leave that suite
        // watching code nothing at runtime actually calls.
        accounts.filter { $0.agent == .claude }.flatMap { account -> [TranscriptRef] in
            let root = account.home.appendingPathComponent("projects", isDirectory: true)
            let entries = SearchCorpus.directories(
                forProjects: projects, projectsRoot: root, listing: listing, exists: exists
            )
            return entries.flatMap { entry in
                Self.transcripts(
                    in: entry.directory, project: entry.projectPath,
                    workingDirectory: entry.workingDirectory, accountHome: account.home,
                    listing: listing
                )
            }
        }
    }

    func indexedMessages(
        inLine line: String, conversationID: String, at offset: Int
    ) -> [IndexedMessage] {
        TranscriptExtractor.messages(inLine: line, conversationID: conversationID, offset: offset)
    }

    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        guard let name = ConversationTitle.resolve(lines: lines) else { return .unknown }
        // `containsRename` moved here from `SearchIndexBuilder`, where it was the one piece
        // of claude-record knowledge left in an otherwise agent-blind actor. A later pass
        // sees only newly appended lines, so it cannot know an earlier pass already found a
        // rename — which is why a name resolved only as a fallback must never overwrite.
        return Self.containsRename(lines) ? .authoritative(name) : .fallback(name)
    }

    /// Every `.jsonl` directly under `directory`, one `TranscriptRef` each.
    ///
    /// Subdirectories are skipped: `~/.claude/projects/<dir>/<conversation>/subagents/*.jsonl`
    /// holds subagent transcripts, which are not conversations anyone resumes and would
    /// double-count text their parent already carries.
    private static func transcripts(
        in directory: URL, project: String, workingDirectory: String, accountHome: URL,
        listing: @Sendable (String) -> [String]
    ) -> [TranscriptRef] {
        listing(directory.path).compactMap { name -> TranscriptRef? in
            guard name.hasSuffix(".jsonl") else { return nil }
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return TranscriptRef(
                url: url, projectPath: project, accountHome: accountHome,
                workingDirectory: workingDirectory,
                conversationID: String(name.dropLast(".jsonl".count)), agent: .claude,
                provenance: nil, indexedName: nil, modified: modified
            )
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
}
