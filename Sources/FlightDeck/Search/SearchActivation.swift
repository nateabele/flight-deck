import FleetKit
import Foundation

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
            conversationID: String, projectPath: String, title: String, transcriptDirectory: String
        )
        /// The project has left the sidebar since this conversation ran; put it back first.
        case addProjectThenResume(
            projectPath: String, conversationID: String, title: String, transcriptDirectory: String
        )
    }

    /// `transcriptDirectory` is a hint, not a guarantee: nothing in `SearchResult` identifies
    /// which of a project's worktrees a conversation actually ran in
    /// (`SearchCorpus`'s doc comment explains why that encoding cannot be decoded back to a
    /// path), so production wiring has no answer to pass and always leaves this `nil`, which
    /// collapses to the project path. `SessionStore.openConversation` does not trust this
    /// field for that reason — it re-resolves the real directory itself, by checking which of
    /// the project's candidate directories actually holds `<conversationID>.jsonl`. This
    /// parameter exists so a test can still hand `plan` a known answer and exercise the
    /// pass-through shape without going near a filesystem.
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
                projectPath: result.projectPath, conversationID: "", title: result.title,
                transcriptDirectory: transcriptDirectory ?? result.projectPath
            )
        }
        // A second `claude --resume` on a live conversation means two processes appending
        // one transcript and colliding in claude's pid-keyed name registry. Selecting the
        // existing tab is both cheaper and the only correct answer.
        if let parsed = UUID(uuidString: conversation),
           let open = openSessions.first(where: { $0.conversationID == parsed }) {
            return .select(open.id)
        }

        let directory = transcriptDirectory ?? result.projectPath
        return projects.contains(result.projectPath)
            ? .resume(
                conversationID: conversation, projectPath: result.projectPath, title: result.title,
                transcriptDirectory: directory
            )
            : .addProjectThenResume(
                projectPath: result.projectPath, conversationID: conversation, title: result.title,
                transcriptDirectory: directory
            )
    }
}
