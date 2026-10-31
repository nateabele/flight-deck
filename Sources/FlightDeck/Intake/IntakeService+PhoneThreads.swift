import Foundation
import FleetKit
import IntakeKit

/// The phone's ask-thread ops (`intake.thread.*`, `intake.diff.decide`), as `FleetService`
/// dispatches them. Stream D owns this file and fills these in; until then each refuses with
/// `threads_unavailable`, and the detail's `threads` flag stays off so a phone never sends one.
///
/// `String?` like the sibling phone ops: nil is accepted, otherwise the `err` code. They are
/// token-idempotent through the same memory (`alreadyAccepted` / `accept` / `refuse`).
///
/// **New-thread id contract.** `phoneThreadSend` with `threadID: nil` opens thread
/// `ThreadID.opened(byToken: token)` — `ThreadID(raw: token)` — and its first message's
/// `messageID` is `ThreadCommand.firstMessageID(token:)`, `token.uuidString`. A retry after a
/// lost ack carries the same token, so it names the same thread and the same message, and
/// ThreadRunner (which dedupes on `messageID`, R9) opens no second thread and runs no second
/// turn. The phone's outbox can therefore show the new thread under that id before the Mac
/// answers.
extension IntakeService {
    func phoneThreadSend(_ id: UUID, token: UUID, threadID: UUID?, anchor: WireThreadAnchor?, text: String) -> String? {
        Self.threadsUnavailable
    }

    /// Answers to a turn's `askQuestion` actions; queues the thread's next turn.
    func phoneThreadAnswer(_ id: UUID, token: UUID, threadID: UUID, answers: [WireStructuredAnswer]) -> String? {
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
}
