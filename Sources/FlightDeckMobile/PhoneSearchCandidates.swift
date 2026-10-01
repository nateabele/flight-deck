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
                // The Mac's word for which conversation this tab is pinned to. Falling back to
                // the tab id lowercased covers a Mac that predates the map: a claude tab starts
                // pinned to its own id. Lowercased because a transcript filename stem is
                // lowercase and `UUID.uuidString` is not — comparing them raw never matches,
                // which would silently defeat the claim and list every open session twice.
                let key = catalogue.sessionConversations[session.id.uuidString]
                    ?? session.id.uuidString.lowercased()
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
                    // Carried so `SearchRanker` can tell this tab's transcript hits come from an
                    // open session. Activation goes by `kind`, so this changes no tap.
                    conversationID: key,
                    agent: session.agent
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
                conversationID: conversation.id,
                agent: conversation.agent
            ))
        }
        return candidates
    }
}
