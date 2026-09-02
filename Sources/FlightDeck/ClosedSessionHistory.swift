import Foundation

/// What ⌘⇧T walks back through: the sessions and projects closed during this run, most
/// recent first.
///
/// A pure value type with no reference to `SessionStore`. It decides only the order things
/// come back in and how many are remembered; *what* to record and how to rebuild it are the
/// store's business, which keeps this testable without a surface, a shell, or an agent.
///
/// In-memory for the life of the run, deliberately — nothing here is persisted. A relaunch
/// already restores the deck you left, so a stack that survived one would offer to reopen
/// tabs you closed in a session you have since replaced.
struct ClosedSessionHistory {
    /// One closed tab, with enough of its surroundings to put it back where it was. The whole
    /// `Session` value is kept rather than its fields: reopening reuses its `id` and
    /// `pinnedConversationID`, which is what makes the rebuilt tab resume the actual
    /// conversation instead of starting a fresh one.
    struct ClosedSession: Equatable {
        let session: Session
        /// The project it was filed under, as a path rather than a `Repo.ID`: closing the last
        /// session in a project leaves the project standing, but closing the *project* does
        /// not, and a reopen that recreates it mints a new id. The path survives both.
        let projectPath: String
        /// Its row position within that project, so a reopen lands it back among its siblings
        /// rather than at the bottom.
        let indexInProject: Int
    }

    /// A closed project and everything that was in it, recorded as one entry so a single
    /// reopen brings the whole thing back — the way a browser reopens a closed window rather
    /// than making you undo its tabs one at a time.
    struct ClosedProject: Equatable {
        let path: String
        let isCollapsed: Bool
        /// Its position among the sidebar's projects.
        let indexInSidebar: Int
        /// In sidebar order. Each carries its own `indexInProject`, which is what puts them
        /// back in that order even though they are re-inserted one at a time.
        let sessions: [ClosedSession]
    }

    enum Entry: Equatable {
        case session(ClosedSession)
        case project(ClosedProject)
    }

    /// How many closes are remembered. Every close pushes, so without a cap this grows for
    /// the life of the run — and a stack deep enough to hold a day's closes is a stack whose
    /// far end nobody will ever reach for.
    static let depth = 20

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Pushes onto the top of the stack, forgetting from the far end once `depth` is reached.
    mutating func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.depth {
            entries.removeFirst(entries.count - Self.depth)
        }
    }

    /// Pops the most recent close, or nil when there is nothing left to reopen.
    mutating func takeLast() -> Entry? {
        entries.popLast()
    }

    /// The top-level closed sessions, most recent first — what a menu lists.
    ///
    /// **Top-level only.** A `ClosedProject`'s children are deliberately absent: offering one
    /// on its own would let a reopen consume half a project entry, and the later ⌘⇧T that
    /// reopened the project would try to reinsert a tab that is already open. A project comes
    /// back whole or not at all, which is the promise `record(.project(_:))` makes.
    ///
    /// Reversed rather than stored reversed, because `record` and `takeLast` both want the
    /// newest at the end and they are the hot path.
    var sessionEntries: [ClosedSession] {
        entries.reversed().compactMap { entry in
            guard case .session(let closed) = entry else { return nil }
            return closed
        }
    }

    /// Removes and returns the top-level `.session` entry for `id`, or nil when there is none.
    ///
    /// **Removal is forced, not a policy.** `SessionStore.reinsertClosed` rebuilds the tab from
    /// the recorded `Session` value, reusing its `id` — that is what makes it resume the real
    /// conversation. Leaving the entry behind would let a later ⌘⇧T insert a second tab with
    /// the same UUID, and `locate(id)` would then find one of two.
    ///
    /// Removes from the middle. `takeLast` goes on popping whatever is left on top.
    mutating func takeSession(id: UUID) -> ClosedSession? {
        let found = entries.firstIndex { entry in
            guard case .session(let closed) = entry else { return false }
            return closed.session.id == id
        }
        guard let found, case .session(let closed) = entries.remove(at: found) else { return nil }
        return closed
    }
}
