import Foundation

/// The single place codex's `ThreadStatus` becomes a `SessionActivity`.
///
/// It exists because there were two of these and they disagreed. `CodexEventMapper` and
/// `CodexAdapter.read` each carried their own table, both written from a vocabulary
/// (`running`, `busy`) that **does not exist in the protocol** — so a working thread read as
/// idle on one path and as nothing at all on the other. One function, two call sites.
///
/// The real union, quoted from `ThreadStatus` in the schema emitted by
/// `codex app-server generate-json-schema` at codex-cli 0.147.0:
///
///     notLoaded | idle | systemError | active { activeFlags: [ThreadActiveFlag] }
///     ThreadActiveFlag = waitingOnApproval | waitingOnUserInput
///
/// It arrives as an *object* tagged by `type`, not as a bare string — `activeFlags` rides
/// alongside the tag, and is the only signal codex gives that a thread is blocked on the
/// user rather than working.
enum CodexThreadStatus {
    /// Maps a `ThreadStatus` object to what the sidebar should show, or `nil` for "this says
    /// nothing — keep whatever is already known".
    ///
    /// `nil` is the default on purpose. A status this app has never heard of must not be
    /// guessed at: pinning `.busy` on an unknown value leaves a spinner running forever, and
    /// pinning `.idle` hides real work. That is also why the mapping is written as an
    /// enumeration of the states we understand rather than as an `if busy else idle`.
    ///
    /// - `notLoaded` deliberately maps to `nil` rather than `.idle`. Probed against a real
    ///   `codex app-server` at 0.147.0: `thread/read` on a thread that exists on disk but is
    ///   not open in this process succeeds with `notLoaded`. It means "nobody has opened
    ///   this", which is an absence of information about activity, not a claim of idleness —
    ///   and it is the status every restored tab sees first.
    /// - `systemError` maps to `.idle`: the thread has stopped, whatever went wrong, and the
    ///   one thing that must not happen is a spinner left turning on a dead thread. There is
    ///   no error case in `SessionActivity` to say more than that.
    static func activity(from status: [String: Any]?) -> SessionActivity? {
        switch status?["type"] as? String {
        case "idle": return .idle
        case "systemError": return .idle
        case "active":
            // Empty flags means working; any flag means blocked on the user. Read
            // permissively — a flag value we do not recognise still means *some* block, so
            // non-empty is the test rather than membership of a known set.
            let flags = status?["activeFlags"] as? [Any] ?? []
            return flags.isEmpty ? .busy : .waiting
        default: return nil
        }
    }
}
