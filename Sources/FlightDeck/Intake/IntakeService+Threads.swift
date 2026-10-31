import Foundation
import IntakeKit

/// Why a thread operation was refused. `code` is the machine-readable contract, the same
/// string the phone receives as an `err` code.
struct ThreadRefusal: Error, Equatable {
    let code: String
}

/// Ask threads' entry points on the Mac (P1 Task 0): the API the Mac UI (Stream C) sends
/// through. Every one refuses with `threads_unavailable` and queues nothing until Stream A's
/// runner exists: the shapes land first so the streams can code against them at once, and
/// nothing behind them runs yet. The phone's ops are `IntakeService+PhoneThreads`.
extension IntakeService {
    static let threadsUnavailable = "threads_unavailable"

    /// Whether this Mac runs ask threads: what the detail projection's `threads` flag and the
    /// Mac's ✦ Ask follow. Off until ThreadRunner ships.
    var threadsAvailable: Bool { false }

    /// `id`'s threads as ThreadRunner last wrote them; nil while threads are unavailable.
    func threadReader(_ id: UUID) -> (any ThreadStoreReading)? { nil }

    /// What the detail pane hands `PlanNotesController` for intake `id`: the reader and the send
    /// API in one value, so the Ask cards and the thread panel are built on it without the
    /// detail view changing again.
    func threadBinding(for id: UUID) -> IntakeThreadBinding {
        IntakeThreadBinding(intakeID: id, reader: threadReader(id) ?? EmptyThreadStore(), service: self)
    }

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

    static var unavailable: ThreadRefusal { ThreadRefusal(code: threadsUnavailable) }
}

/// One intake's ask threads as the Mac UI holds them: what to read, and where each send goes —
/// `IntakeService`'s own API above, for this intake. Weak to the service, as the notes
/// controller's other closures are bound: the view state must not keep a service alive.
@MainActor
struct IntakeThreadBinding {
    let intakeID: UUID
    let reader: any ThreadStoreReading
    weak var service: IntakeService?

    func open(anchor: ThreadAnchor, title: String, text: String, agent: AgentID, model: String,
              effort: String) -> Result<ThreadID, ThreadRefusal> {
        guard let service else { return .failure(IntakeService.unavailable) }
        return service.openThread(intakeID, anchor: anchor, title: title, text: text, agent: agent, model: model,
                                  effort: effort)
    }

    func send(_ thread: ThreadID, text: String) -> ThreadRefusal? {
        service?.sendThreadMessage(intakeID, thread: thread, text: text) ?? IntakeService.unavailable
    }

    func answer(_ thread: ThreadID, answers: [StructuredAnswer]) -> ThreadRefusal? {
        service?.answerThread(intakeID, thread: thread, answers: answers) ?? IntakeService.unavailable
    }

    func setAutoAccept(_ thread: ThreadID, _ on: Bool) -> ThreadRefusal? {
        service?.setThreadAutoAccept(intakeID, thread: thread, on) ?? IntakeService.unavailable
    }

    func setAgent(_ thread: ThreadID, agent: AgentID, model: String, effort: String) -> ThreadRefusal? {
        service?.setThreadAgent(intakeID, thread: thread, agent: agent, model: model, effort: effort) ?? IntakeService.unavailable
    }

    func resolve(_ thread: ThreadID) -> ThreadRefusal? {
        service?.resolveThread(intakeID, thread: thread) ?? IntakeService.unavailable
    }

    func reopen(_ thread: ThreadID) -> ThreadRefusal? {
        service?.reopenThread(intakeID, thread: thread) ?? IntakeService.unavailable
    }

    func decideDiff(_ thread: ThreadID, diff: UUID, accept: Bool) -> ThreadRefusal? {
        service?.decideDiff(intakeID, thread: thread, diff: diff, accept: accept) ?? IntakeService.unavailable
    }

    func repropose(_ thread: ThreadID, diff: UUID) -> ThreadRefusal? {
        service?.reproposeDiff(intakeID, thread: thread, diff: diff) ?? IntakeService.unavailable
    }
}
