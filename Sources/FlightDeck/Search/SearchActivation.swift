import FleetKit
import Foundation
import IntakeKit

/// What Return on a search result means.
///
/// Pure and separate from `SessionStore` on purpose: "should this select a tab or launch an
/// agent" is a rule worth testing exhaustively, and testing it inside the store would mean
/// spawning processes to assert a branch.
enum SearchActivation {
    /// A tab currently in the deck, reduced to the two fields activation cares about.
    ///
    /// `conversationID` is a `UUID`, not the raw string a result carries: `UUID.uuidString`
    /// is uppercase, and a transcript filename stem (what `SearchResult.conversationID`
    /// holds) is lowercase. Comparing those as strings would never match, silently defeating
    /// the "already open" check below — typing this as `UUID` makes that mismatch
    /// unrepresentable rather than relying on every caller to remember to lowercase.
    struct ActiveSession: Equatable {
        let id: UUID
        let conversationID: UUID
    }

    enum Activation: Equatable {
        /// Already open. Select it.
        case select(UUID)
        /// Resume into a new tab under a project that is already in the sidebar.
        case resume(
            conversationID: String, projectPath: String, title: String, agent: AgentID,
            workingDirectory: String, transcriptPath: String
        )
        /// The project has left the sidebar since this conversation ran; put it back first.
        case addProjectThenResume(
            projectPath: String, conversationID: String, title: String, agent: AgentID,
            workingDirectory: String, transcriptPath: String
        )
    }

    /// `result.agent` degrades to `.claude` when it names an agent this build does not
    /// recognise — the same fallback `TranscriptHit.agent`'s own doc comment specifies for
    /// the wire decode. A result naming a future agent must still resume as *something*
    /// rather than crash the search panel.
    ///
    /// `workingDirectory` and `transcriptPath` are passed through from the result exactly as
    /// carried — empty means unknown, and it is `SessionStore.openConversation`'s job to
    /// decide what an unknown one falls back to, not this pure planning step's.
    static func plan(
        for result: SearchResult,
        openSessions: [ActiveSession],
        projects: [String]
    ) -> Activation {
        if case .session(let id) = result.kind { return .select(id) }

        let agent = AgentID(rawValue: result.agent) ?? .claude

        guard let conversation = result.conversationID else {
            // A project row with no conversation: selecting the project is the closest
            // meaningful action, and the store resolves it to the project's first session.
            return .addProjectThenResume(
                projectPath: result.projectPath, conversationID: "", title: result.title,
                agent: agent, workingDirectory: result.workingDirectory,
                transcriptPath: result.transcriptPath
            )
        }
        // A second `claude --resume` (or a second codex resume, which codex refuses outright
        // rather than merely tolerating badly) on a live conversation means two processes
        // appending one transcript. Selecting the existing tab is both cheaper and the only
        // correct answer, for either agent.
        if let parsed = UUID(uuidString: conversation),
           let open = openSessions.first(where: { $0.conversationID == parsed }) {
            return .select(open.id)
        }

        return projects.contains(result.projectPath)
            ? .resume(
                conversationID: conversation, projectPath: result.projectPath, title: result.title,
                agent: agent, workingDirectory: result.workingDirectory,
                transcriptPath: result.transcriptPath
            )
            : .addProjectThenResume(
                projectPath: result.projectPath, conversationID: conversation, title: result.title,
                agent: agent, workingDirectory: result.workingDirectory,
                transcriptPath: result.transcriptPath
            )
    }
}
