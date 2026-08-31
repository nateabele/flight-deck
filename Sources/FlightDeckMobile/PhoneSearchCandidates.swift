import FleetKit
import Foundation

/// Flattens what the phone holds into the list `SearchRanker` matches names against.
///
/// The phone's answer to the Mac's `SearchCandidates`, and deliberately a separate type
/// rather than a shared one: that reads `Repo` and `ClaudeSession`, which are Mac types that
/// exist to derive filesystem paths. The *rules* are shared — through `SearchRanker` — and
/// the sources are not.
enum PhoneSearchCandidates {
    static func build(
        projects: [WireProject], catalogue: WireConversationCatalogue
    ) -> [NameCandidate] {
        var candidates: [NameCandidate] = []
        var claimed: Set<String> = []

        for project in projects {
            var newest = Date.distantPast
            for session in project.sessions {
                // Lowercased because a transcript filename stem is lowercase and
                // `UUID.uuidString` is not — comparing them raw never matches, which would
                // silently defeat the claim below and list every open session twice.
                let key = session.id.uuidString.lowercased()
                claimed.insert(key)
                let stamp = catalogue.sessionActivity[session.id.uuidString] ?? .distantPast
                newest = max(newest, stamp)
                candidates.append(NameCandidate(
                    id: session.id.uuidString,
                    kind: .session(session.id),
                    name: session.title,
                    projectPath: project.path,
                    projectName: project.name,
                    lastActivity: stamp,
                    conversationID: nil
                ))
            }
            candidates.append(NameCandidate(
                id: "project:\(project.path)",
                kind: .project,
                name: project.name,
                projectPath: project.path,
                projectName: project.name,
                lastActivity: newest,
                conversationID: nil
            ))
        }

        let open = Set(projects.map(\.path))
        // Sorted by id so the list is deterministic: `SearchRanker`'s final tiebreak is the
        // result id, and a candidate list that reshuffled between calls would defeat it.
        for conversation in catalogue.conversations.sorted(by: { $0.id < $1.id })
        where !claimed.contains(conversation.id) && open.contains(conversation.projectPath) {
            candidates.append(NameCandidate(
                id: "conversation:\(conversation.id)",
                kind: .conversation(conversation.id),
                name: conversation.name,
                projectPath: conversation.projectPath,
                projectName: URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                // Unknown without stat-ing every historical transcript on the Mac, which the
                // desktop declines to do for the same reason. Sorting last within a tier is
                // the right default: anything with a live tab is likelier to be wanted.
                lastActivity: .distantPast,
                conversationID: conversation.id
            ))
        }
        return candidates
    }
}

// Note the claim key. A `WireSession` does not expose its conversation id, so a session is
// matched against the catalogue by its tab id lowercased. For claude these are the same
// value; for codex they are not, so a codex session's past conversation may appear as a
// separate catalogue row. That is the honest limit of what the wire says today — do not
// invent a mapping. If it proves confusing in use, the fix is a `conversationID` on
// `WireSession`, not a guess here.
