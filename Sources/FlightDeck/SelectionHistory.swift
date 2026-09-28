import Foundation

/// One place the user has been shown in the sidebar. A project is keyed by path, not by
/// `Repo.id`: repo ids are minted fresh on every launch (`SessionSnapshot.Project` stores only
/// the path), so an id-keyed entry would be dead after the first relaunch.
enum SelectionTarget: Codable, Hashable {
    case session(id: UUID)
    case project(path: String)
}

/// Decodes one array element independently of its siblings, swallowing its own failure rather
/// than the array's. Plain `[SelectionTarget]` fails the WHOLE array the moment one element is
/// an unknown shape (an old build's `{"session":{"_0":...}}`, a hand-edited file, a future
/// case this build has never heard of) — exactly the all-or-nothing throw `SelectionHistory`
/// exists to avoid. `wrapped` is `nil` for an element that failed; callers drop those with
/// `compactMap`.
private struct Lossy<T: Decodable>: Decodable {
    let wrapped: T?
    init(from decoder: Decoder) {
        wrapped = try? T(from: decoder)
    }
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

    private enum CodingKeys: String, CodingKey { case back, forward }

    init() {}

    /// Hand-written, and never throws — the synthesized version this replaces let one bad
    /// value (an unknown enum case, `"selectionHistory":7`) throw all the way up through
    /// `SessionSnapshot`'s decode, which `load()` then reports as nil: the app starts with
    /// every tab gone, and the next save overwrites `sessions.json` with that emptiness. A
    /// non-object value at this key falls back to empty history via `try?` on the keyed
    /// container itself; a malformed *element* inside `back`/`forward` is dropped by `Lossy`
    /// without disturbing its siblings.
    init(from decoder: Decoder) {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            back = []
            forward = []
            return
        }
        back = Self.decodeStack(container, key: .back)
        forward = Self.decodeStack(container, key: .forward)
    }

    private static func decodeStack(
        _ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) -> [SelectionTarget] {
        // `try?` on `decodeIfPresent` covers both a missing key (returns nil, no throw) and a
        // present-but-wrong-shaped value (`"forward":7` throws a type mismatch) with the same
        // empty-array fallback; a present, array-shaped value still runs each element through
        // `Lossy` before this ever gets the chance to matter.
        guard let lossy = try? container.decodeIfPresent([Lossy<SelectionTarget>].self, forKey: key)
        else { return [] }
        return lossy.compactMap(\.wrapped)
    }

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
