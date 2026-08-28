import Foundation

/// Flattens the deck and the index into the one list `SearchModel` matches names against.
///
/// Three sources: open tabs, the projects holding them, and every conversation the index has
/// a name for. A conversation that already has a tab is contributed by the tab and *not*
/// again by the index, so it appears once rather than twice with two different meanings for
/// Return.
///
/// **Where recency comes from.** The transcript's modification date, for all three. There is
/// no per-session activity timestamp anywhere in the model, and the file already records
/// exactly this — a live session appends to it constantly — so introducing one would
/// duplicate a fact that can then disagree with itself. `modified` is injected so all of this
/// is testable without touching a filesystem.
enum SearchCandidates {
    static func build(
        repos: [Repo],
        conversations: [String: IndexedConversation],
        modified: (URL) -> Date
    ) -> [NameCandidate] {
        var candidates: [NameCandidate] = []
        var claimed: Set<String> = []

        for repo in repos {
            var newest = Date.distantPast
            for session in repo.sessions {
                let conversation = session.pinnedConversationID.uuidString.lowercased()
                claimed.insert(conversation)
                let stamp = modified(ClaudeSession.transcriptURL(
                    sessionID: session.pinnedConversationID,
                    workingDirectory: session.transcriptDirectory
                ))
                newest = max(newest, stamp)
                candidates.append(NameCandidate(
                    id: session.id.uuidString,
                    kind: .session(session.id),
                    name: session.title,
                    projectPath: repo.url.path,
                    projectName: repo.displayName,
                    lastActivity: stamp,
                    conversationID: conversation
                ))
            }
            candidates.append(NameCandidate(
                id: "project:\(repo.url.path)",
                kind: .project,
                name: repo.displayName,
                projectPath: repo.url.path,
                projectName: repo.displayName,
                lastActivity: newest,
                conversationID: nil
            ))
        }

        // `SQLiteSearchIndex.prune` drops a project's message and source rows once it leaves
        // the sidebar, but never its `conversation` rows — so `conversationNames()` keeps
        // answering for a project that is no longer open. Filtered here rather than in the
        // index: leaving a closed project's conversations in this list would offer a name
        // match `SearchActivation.plan` cannot honour without silently re-adding the project
        // to the sidebar the user removed it from on purpose.
        let openProjects = Set(repos.map(\.url.path))

        // Sorted by id so the list is deterministic regardless of dictionary ordering —
        // `SearchRanker`'s final tiebreak is the result id, and a candidate list that
        // reshuffled between calls would defeat it.
        for (id, conversation) in conversations.sorted(by: { $0.key < $1.key })
        where !claimed.contains(id) && openProjects.contains(conversation.projectPath) {
            candidates.append(NameCandidate(
                id: "conversation:\(id)",
                kind: .conversation(id),
                name: conversation.name,
                projectPath: conversation.projectPath,
                projectName: URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                // Unknown without stat-ing every historical transcript, which would put a
                // filesystem walk on the ⌘K keystroke. Historical conversations therefore
                // sort last within their tier, which is the right default: anything with a
                // live tab is more likely to be what you want.
                lastActivity: .distantPast,
                conversationID: id
            ))
        }
        return candidates
    }
}
