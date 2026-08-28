import Foundation

/// What Return on a search result means.
///
/// Pure and separate from `SessionStore` on purpose: "should this select a tab or launch an
/// agent" is a rule worth testing exhaustively, and testing it inside the store would mean
/// spawning processes to assert a branch.
enum SearchActivation {
    /// A tab currently in the deck, reduced to the two fields activation cares about.
    struct ActiveSession: Equatable {
        let id: UUID
        let conversationID: String
    }

    enum Activation: Equatable {
        /// Already open. Select it.
        case select(UUID)
        /// Resume into a new tab under a project that is already in the sidebar.
        case resume(conversationID: String, projectPath: String, transcriptDirectory: String)
        /// The project has left the sidebar since this conversation ran; put it back first.
        case addProjectThenResume(
            projectPath: String, conversationID: String, transcriptDirectory: String
        )
    }

    /// `transcriptDirectory` defaults to the project, and differs only for a conversation
    /// that ran inside a worktree. Getting this wrong is silent: a tab resumed in the project
    /// root would tail a transcript nothing writes to and lose title sync and subagent counts
    /// with no error — the failure `Session.transcriptDirectory` was introduced to prevent.
    static func plan(
        for result: SearchResult,
        openSessions: [ActiveSession],
        projects: [String],
        transcriptDirectory: String? = nil
    ) -> Activation {
        if case .session(let id) = result.kind { return .select(id) }

        guard let conversation = result.conversationID else {
            // A project row with no conversation: selecting the project is the closest
            // meaningful action, and the store resolves it to the project's first session.
            return .addProjectThenResume(
                projectPath: result.projectPath, conversationID: "",
                transcriptDirectory: transcriptDirectory ?? result.projectPath
            )
        }
        // A second `claude --resume` on a live conversation means two processes appending
        // one transcript and colliding in claude's pid-keyed name registry. Selecting the
        // existing tab is both cheaper and the only correct answer.
        if let open = openSessions.first(where: { $0.conversationID == conversation }) {
            return .select(open.id)
        }

        let directory = transcriptDirectory ?? result.projectPath
        return projects.contains(result.projectPath)
            ? .resume(
                conversationID: conversation, projectPath: result.projectPath,
                transcriptDirectory: directory
            )
            : .addProjectThenResume(
                projectPath: result.projectPath, conversationID: conversation,
                transcriptDirectory: directory
            )
    }
}
