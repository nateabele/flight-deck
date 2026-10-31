import FleetKit
import Foundation

/// Which ask-thread surfaces the phone may offer. Every thread op is gated on the Mac's
/// `threads` flag: an older Mac drops the socket on an op it does not know, so the phone
/// never sends one (spec §10).
enum ThreadGate {
    /// Showing threads, their pages and their diffs: the flag alone.
    static func canRead(detail: WireIntakeDetail?) -> Bool { detail?.threads == true }

    /// Sending, answering, resolving and deciding: also an intake that takes steering and is
    /// still shaping, the same rule as notes (`NoteComposer.notesAllowed`) — the Mac refuses
    /// the rest as `intake_moved_on`.
    static func canAsk(detail: WireIntakeDetail?) -> Bool {
        canRead(detail: detail) && NoteComposer.notesAllowed(detail: detail)
    }

    /// Ask in the plan reader: at the head only, for the reason notes are (`PlanReaderStyle.notesAllowed`).
    static func canAskInReader(detail: WireIntakeDetail?, checkpoint: Int?) -> Bool {
        checkpoint == nil && canAsk(detail: detail)
    }
}

/// One message the person composed, to a thread or to open one. `id` is fixed when the draft is
/// made and never minted inside a send: a retry is the same draft.
struct ThreadDraft: Identifiable, Equatable {
    let id: UUID
    /// nil opens a thread; the Mac names it by the send's token (`ThreadID.opened(byToken:)`).
    let threadID: UUID?
    let anchor: WireThreadAnchor?
    var text: String

    init(id: UUID = UUID(), threadID: UUID?, anchor: WireThreadAnchor?, text: String) {
        self.id = id; self.threadID = threadID; self.anchor = anchor; self.text = text
    }
}

/// What the phone sent that the Mac's projection does not show yet (a pattern of `NoteOutbox`).
///
/// **Why an acked send is held on to.** The Mac projects a thread only after ThreadRunner has
/// processed the queued `open`, and shows a message only once its turn lands — and a turn takes
/// a model's time. Without this a new ask would flash, vanish, and reappear later.
///
/// **The token is the identity.** The Mac names a phone-opened thread `ThreadID.opened(byToken:)`
/// and its first message `ThreadCommand.firstMessageID(token:)`, and a reply's `messageID` is
/// its token's string. The outbox records the token each send used, so it can show the new
/// thread under its real id before the Mac answers, and recognise its message in the turns.
struct ThreadOutbox: Equatable {
    private struct Entry: Equatable {
        var draft: ThreadDraft
        var token: UUID?
        var acked = false
    }
    private var entries: [Entry] = []
    private var decisions: [UUID: Bool] = [:]

    /// Not acked: drawn with "Not yet sent", or the failure and a Retry.
    var unsent: [ThreadDraft] { entries.filter { !$0.acked }.map(\.draft) }

    /// Add a draft, or replace it (a retry is the same draft).
    mutating func submit(_ draft: ThreadDraft) {
        if let i = entries.firstIndex(where: { $0.draft.id == draft.id }) {
            entries[i] = Entry(draft: draft, token: entries[i].token)
        } else {
            entries.append(Entry(draft: draft))
        }
    }

    /// The token this send carries. A retry after a timeout keeps it; a fresh press mints another,
    /// and the latest is the one an ack can be about.
    mutating func sending(_ id: UUID, token: UUID) {
        if let i = entries.firstIndex(where: { $0.draft.id == id }) { entries[i].token = token }
    }

    mutating func acked(_ id: UUID) {
        if let i = entries.firstIndex(where: { $0.draft.id == id }) { entries[i].acked = true }
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.draft.id == id } }

    /// The thread an acked opening draft became.
    func openedThread(of draftID: UUID) -> UUID? {
        entries.first { $0.draft.id == draftID && $0.draft.threadID == nil && $0.acked }?.token
    }

    /// The Mac's threads with this phone's acked, not-yet-listed new ones on top.
    func listing(_ threads: [WireThreadSummary]) -> [WireThreadSummary] {
        let listed = Set(threads.map(\.id))
        let pending = entries.compactMap { e -> WireThreadSummary? in
            guard e.acked, e.draft.threadID == nil, let token = e.token, !listed.contains(token) else { return nil }
            return WireThreadSummary(id: token, title: Self.title(e.draft.text), anchor: e.draft.anchor,
                                     status: "answering", counts: WireThreadCounts())
        }
        return threads + pending
    }

    /// Messages in `thread` the turns do not hold yet: replies to it, and the opening message of
    /// a thread this phone just opened.
    func pendingMessages(in thread: UUID) -> [ThreadDraft] {
        entries.filter { e in
            guard e.acked else { return false }
            return e.draft.threadID == thread || (e.draft.threadID == nil && e.token == thread)
        }.map(\.draft)
    }

    /// From the plan's thread list: an opening draft leaves once the Mac lists its thread with a
    /// turn. Its message is dropped by the turns, in `reconcile(thread:turns:)`.
    mutating func reconcile(threads: [WireThreadSummary]) {
        let withTurns = Set(threads.filter { $0.counts.turns > 0 }.map(\.id))
        entries.removeAll { e in
            e.acked && e.draft.threadID == nil && e.token.map(withTurns.contains) == true
        }
    }

    /// From a thread's turns: a message the Mac holds is no longer pending.
    mutating func reconcile(thread: UUID, turns: [WireThreadTurn]) {
        let held = Set(turns.map(\.messageID))
        entries.removeAll { e in
            guard e.acked, let token = e.token, held.contains(token.uuidString) else { return false }
            return e.draft.threadID == thread || (e.draft.threadID == nil && token == thread)
        }
    }

    // MARK: - Diffs

    /// A ✓ or ✗ the Mac acked. A runner applies it after the ack, so until the plan stops
    /// listing the diff as pending the reader keeps drawing the decision (accepted: the new
    /// text, rejected: the old), instead of flashing back to a pending diff.
    mutating func decided(_ diff: UUID, accept: Bool) { decisions[diff] = accept }

    func decision(for diff: UUID) -> Bool? { decisions[diff] }

    mutating func reconcile(diffs: [WirePendingDiff]) {
        let pending = Set(diffs.filter { $0.state == "pending" }.map(\.id))
        decisions = decisions.filter { pending.contains($0.key) }
    }

    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}

/// One intake's `ThreadOutbox` as an observable: the reader and the thread screen both draw
/// from it, and a send from either must redraw the other.
@MainActor
@Observable
final class ThreadOutboxModel {
    var outbox = ThreadOutbox()
}

extension FlightControlModel {
    /// Sends a composed message. It is listed as unsent first, so the tap changes the screen
    /// before any answer. The token each send uses is recorded as the command is built — the
    /// Mac names a new thread by it — and a retry after a timeout reuses it (`IntakeCommandModel`).
    func sendThread(_ draft: ThreadDraft, intake: UUID, onAck: @escaping () -> Void = {}) {
        let model = threadOutbox(for: intake)
        model.outbox.submit(draft)
        commands(for: intake).send(.threadSend(draft.id), command: { token in
            model.outbox.sending(draft.id, token: token)
            return .intakeThreadSend(id: intake, token: token, threadID: draft.threadID, anchor: draft.anchor, text: draft.text)
        }, onAck: {
            model.outbox.acked(draft.id)
            onAck()
        })
    }

    func decideDiff(_ diff: WirePendingDiff, accept: Bool, intake: UUID, onAck: @escaping () -> Void = {}) {
        let model = threadOutbox(for: intake)
        commands(for: intake).send(.diffDecide(diff.id), command: {
            .intakeDiffDecide(id: intake, token: $0, threadID: diff.thread, diffID: diff.id, accept: accept)
        }, onAck: {
            model.outbox.decided(diff.id, accept: accept)
            onAck()
        })
    }

    func resolveThread(_ thread: UUID, intake: UUID, onAck: @escaping () -> Void = {}) {
        commands(for: intake).send(.threadResolve(thread), command: {
            .intakeThreadResolve(id: intake, token: $0, threadID: thread)
        }, onAck: onAck)
    }

    func answerThread(_ thread: UUID, answers: [WireStructuredAnswer], intake: UUID, onAck: @escaping () -> Void = {}) {
        commands(for: intake).send(.threadAnswer(thread), command: {
            .intakeThreadAnswer(id: intake, token: $0, threadID: thread, answers: answers)
        }, onAck: onAck)
    }
}
