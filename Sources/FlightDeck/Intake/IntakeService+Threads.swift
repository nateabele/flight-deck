import Foundation
import FleetKit
import IntakeKit

/// Why a thread operation was refused. `code` is the machine-readable contract, the same
/// string the phone receives as an `err` code.
struct ThreadRefusal: Error, Equatable {
    let code: String
}

/// Ask threads' entry points on the Mac (P1 Task 0): the API the Mac UI (Stream C) sends
/// through and the phone ops (Stream D) answer from. Every one refuses with
/// `threads_unavailable` and queues nothing until the streams fill them in: the shapes land
/// first so five streams can code against them at once, and nothing behind them runs yet.
/// The detail's `threads` flag stays off meanwhile, so the phone never sends these.
extension IntakeService {
    static let threadsUnavailable = "threads_unavailable"

    /// Whether this Mac runs ask threads: what the detail projection's `threads` flag and the
    /// Mac's ✦ Ask follow. Off until ThreadRunner ships.
    var threadsAvailable: Bool { false }

    /// `id`'s threads as ThreadRunner last wrote them; nil while threads are unavailable.
    func threadReader(_ id: UUID) -> (any ThreadStoreReading)? { nil }

    // MARK: - The Mac's own

    /// A new thread on `anchor`, with its first message. Returns the thread's id at once; the
    /// turn runs in ThreadRunner.
    func openThread(_ id: UUID, anchor: ThreadAnchor, title: String, text: String, agent: AgentID, model: String,
                    effort: String) -> Result<ThreadID, ThreadRefusal> {
        .failure(Self.unavailable)
    }

    func sendThreadMessage(_ id: UUID, thread: ThreadID, text: String) -> ThreadRefusal? { Self.unavailable }

    /// Answers to the questions a turn asked (`askQuestion`).
    func answerThread(_ id: UUID, thread: ThreadID, answers: [StructuredAnswer]) -> ThreadRefusal? { Self.unavailable }

    func setThreadAutoAccept(_ id: UUID, thread: ThreadID, _ on: Bool) -> ThreadRefusal? { Self.unavailable }

    func setThreadAgent(_ id: UUID, thread: ThreadID, agent: AgentID, model: String, effort: String) -> ThreadRefusal? {
        Self.unavailable
    }

    func resolveThread(_ id: UUID, thread: ThreadID) -> ThreadRefusal? { Self.unavailable }

    func reopenThread(_ id: UUID, thread: ThreadID) -> ThreadRefusal? { Self.unavailable }

    /// ✓ or ✗ on a pending diff. An accept also puts `TapeCommand.applyThreadDiff` on the tape.
    func decideDiff(_ id: UUID, thread: ThreadID, diff: UUID, accept: Bool) -> ThreadRefusal? { Self.unavailable }

    /// One turn against the newest checkpoint for a stale diff.
    func reproposeDiff(_ id: UUID, thread: ThreadID, diff: UUID) -> ThreadRefusal? { Self.unavailable }

    // MARK: - The phone's (`intake.thread.*`, `intake.diff.decide`)

    /// `String?` like the sibling phone ops: nil is accepted, otherwise the `err` code.
    func phoneThreadSend(_ id: UUID, token: UUID, threadID: UUID?, anchor: WireThreadAnchor?, text: String) -> String? {
        Self.threadsUnavailable
    }

    func phoneThreadResolve(_ id: UUID, token: UUID, threadID: UUID) -> String? { Self.threadsUnavailable }

    /// Refused with `diff_stale` once threads ship, when the diff could not be rebased.
    func phoneDiffDecide(_ id: UUID, token: UUID, threadID: UUID, diffID: UUID, accept: Bool) -> String? {
        Self.threadsUnavailable
    }

    func phoneThreadGet(_ id: UUID, threadID: UUID, since: Int?) -> Result<WireThreadPage, ThreadRefusal> {
        .failure(Self.unavailable)
    }

    private static var unavailable: ThreadRefusal { ThreadRefusal(code: threadsUnavailable) }
}
