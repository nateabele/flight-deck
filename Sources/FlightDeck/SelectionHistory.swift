import Foundation

/// One place the user has been shown in the sidebar. A project is keyed by path, not by
/// `Repo.id`: repo ids are minted fresh on every launch (`SessionSnapshot.Project` stores only
/// the path), so an id-keyed entry would be dead after the first relaunch.
enum SelectionTarget: Codable, Hashable {
    case session(UUID)
    case project(path: String)
}

/// ⌃⌘← / ⌃⌘→, browser-style: selecting somewhere new pushes where you were and clears
/// Forward.
///
/// Dead entries (a closed session, a removed project) are pruned only when a traversal skips
/// them, never eagerly: ⌘⇧T reopens a closed session under its original id, so an entry that is
/// dead now can be live again by the time the user presses Back. Never deduplicated either —
/// "Back" means "where I was last", which dedup would break.
struct SelectionHistory: Codable, Equatable {
    private(set) var back: [SelectionTarget] = []
    private(set) var forward: [SelectionTarget] = []

    /// Per stack. Bounds `sessions.json` growth for a user who never relaunches.
    static let limit = 50

    var isEmpty: Bool { back.isEmpty && forward.isEmpty }

    mutating func record(from: SelectionTarget?, to: SelectionTarget?) {
        // `selectedSessionID`'s `didSet` fires on every assignment, including a click on the
        // already-selected row; without this guard each such click would push a duplicate.
        guard let from, let to, from != to else { return }
        Self.push(from, onto: &back)
        forward.removeAll()
    }

    mutating func goBack(
        from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool
    ) -> SelectionTarget? {
        Self.traverse(pop: &back, push: &forward, from: current, isLive: isLive)
    }

    mutating func goForward(
        from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool
    ) -> SelectionTarget? {
        Self.traverse(pop: &forward, push: &back, from: current, isLive: isLive)
    }

    private static func traverse(
        pop source: inout [SelectionTarget], push destination: inout [SelectionTarget],
        from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool
    ) -> SelectionTarget? {
        while let candidate = source.popLast() {
            guard isLive(candidate) else { continue }
            // Pushed only once a destination exists: with nothing to go to, the selection does
            // not move, and recording `current` would leave a Forward entry pointing at the
            // very row the user is still on.
            if let current { push(current, onto: &destination) }
            return candidate
        }
        return nil
    }

    private static func push(_ target: SelectionTarget, onto stack: inout [SelectionTarget]) {
        stack.append(target)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }
}
