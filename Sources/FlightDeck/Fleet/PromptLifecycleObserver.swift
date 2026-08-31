import FleetKit
import Foundation

/// Watches the fleet's own outbound traffic and records what it says about open dialogs.
///
/// **The push side of the prompt question; `PromptService` is the inbound side.** Between them
/// they answer the one thing nothing recorded: when a dialog opens and closes on this Mac,
/// what — if anything — leaves the machine.
///
/// **There is still no prompt on the wire, only its identity.** `OpenPrompt` is *derived* on
/// both ends from a transcript each already holds (see that type, and `FleetCommand`'s own
/// note that only the answer travels); what a session's status now also carries is the blocked
/// call's id, `WireSession.openPromptCall`. That is what this observer was built to find
/// missing: a dialog replaced by the next one, with the session never leaving `waiting`, used
/// to move nothing on the wire at all, and this log's `superseded` records with no `push`
/// beside them are the evidence that closed it.
///
/// The records here are still about `activity` alone, deliberately: `asserts: .open` means the
/// frame said `waiting`, which is the claim a card's *existence* rests on. What dialog it was
/// is the `opened`/`closed` pair above it.
///
/// Reads the store; writes nothing to it, sends nothing, and schedules nothing. It is invoked
/// after the frames it describes have already gone.
@MainActor
final class PromptLifecycleObserver {
    /// What this Mac last decided about one session — the two facts a client's view is built
    /// from, kept apart because they move independently.
    private struct Belief: Equatable {
        /// Whether the last frame about this session asserted a dialog was up. This is the
        /// only part a client is ever told.
        var isWaiting: Bool
        /// The call this Mac derives as open, or `nil` for none it can name. A client is never
        /// told this and must arrive at it itself, which is exactly where the two can diverge.
        var call: String?
    }

    private let store: SessionStore
    /// The same instance `FleetService` answers commands through, so the derivation this logs
    /// and the derivation a tap is judged against are one call to one object over one
    /// transcript. A second `PromptService` here would be a second opinion, and a log that
    /// disagreed with the refusal it was supposed to explain is worse than no log.
    private let prompts: PromptService

    private var beliefs: [UUID: Belief] = [:]

    init(store: SessionStore, prompts: PromptService) {
        self.store = store
        self.prompts = prompts
    }

    /// One batch of events, after they have been broadcast.
    ///
    /// `clients` is read once by the caller for the whole batch rather than per event: it is
    /// the number every `broadcast` in that loop reached, and `attached` moves only on the
    /// same queue this runs on, so it cannot have changed between them.
    func observe(_ batch: [SequencedEvent], clients: Int) {
        for entry in batch {
            switch entry.event {
            case .activityChanged(let id, let activity, _, _, _, _):
                note(id, activity: activity, clients: clients)
            case .sessionAdded(let session, _, _):
                // A tab can be added already blocked — a restore, or a session adopted from a
                // registry that was ahead of us. Its `WireSession.activity` is the same
                // assertion an `activityChanged` carries, so it goes through the same door.
                note(session.id, activity: session.activity, clients: clients)
            case .sessionRemoved(let id):
                remove(id, clients: clients)
            default:
                continue
            }
        }
    }

    /// What a client that has just said `hello` was handed.
    ///
    /// Recorded because a phone that was away across a close learns about it from exactly one
    /// frame and never hears again: if this resume is wrong, its card stays up forever and
    /// nothing later corrects it. `waiting` counts how many sessions the answer asserts a
    /// dialog for — in a snapshot, directly; in a replay, from the activity edges it carries.
    func observeResume(lastSeq: Int, frames: [ServerFrame], clients: Int) {
        var mode = "replay"
        var waiting = 0
        for frame in frames {
            switch frame {
            case .snapshot(_, let fleet, let reason):
                mode = "snapshot-\(reason.rawValue)"
                waiting += fleet.projects
                    .flatMap(\.sessions)
                    .filter { $0.activity == SessionActivity.waiting.rawValue }
                    .count
            case .event(_, .activityChanged(_, let activity, _, _, _, _)):
                if activity == SessionActivity.waiting.rawValue { waiting += 1 }
            default:
                continue
            }
        }
        record(PromptLifecycleRecord(
            session: nil,
            event: .resumed(
                lastSeq: lastSeq, mode: mode, frames: frames.count, waiting: waiting,
                clients: clients
            )
        ))
    }

    /// One session's activity edge: what changed about the dialog, then what was pushed.
    ///
    /// In that order, because that is the order it happened in — the derivation is a fact
    /// about this machine and the push is what the other machine got, and a reader chasing a
    /// stale card is asking whether the second followed the first.
    private func note(_ id: UUID, activity: String?, clients: Int) {
        let previous = beliefs[id]
        let isWaiting = activity == SessionActivity.waiting.rawValue
        // A tab first seen idle or busy says nothing about a dialog and never had one. Filing
        // the belief without a record is what keeps this log proportional to dialogs rather
        // than to tabs: every launch would otherwise open with one line per restored session.
        guard previous != nil || isWaiting else {
            beliefs[id] = Belief(isWaiting: false, call: nil)
            return
        }

        var open: OpenPrompt?
        var refusal: String?
        if isWaiting {
            switch derive(id) {
            case .success(let prompt): open = prompt
            case .failure(let code): refusal = code.code
            }
        }
        let now = Belief(isWaiting: isWaiting, call: open?.callID)
        guard now != previous else { return }

        if let was = previous?.call, was != now.call {
            record(id, .closed(call: was, reason: closeReason(
                isWaiting: isWaiting, activity: activity, open: open, refusal: refusal
            )))
        }
        if let open, open.callID != previous?.call {
            record(
                id,
                .opened(call: open.callID, agent: store.agent(of: id)?.rawValue,
                        kind: Self.kind(of: open)),
                detail: Self.detail(of: open)
            )
        }
        // Only on the edge INTO waiting. A session that was already waiting with nothing
        // nameable and still has nothing has not changed, and one that lost a call it did have
        // is reported by the `closed` above — repeating it here would file two records for one
        // transition and make the log's line count meaningless.
        if isWaiting, open == nil, previous?.isWaiting != true {
            record(id, .unnamed(code: refusal ?? "-"))
        }
        if previous?.isWaiting != isWaiting {
            record(id, .pushed(
                asserts: isWaiting ? .open : .absent, activity: activity, clients: clients
            ))
        }
        beliefs[id] = now
    }

    /// A tab that went away. The removal frame is itself the assertion that nothing is open,
    /// so it is recorded as a push like any other — a client that applies it correctly cannot
    /// keep a card, and one that does not is the failure this is here to catch.
    private func remove(_ id: UUID, clients: Int) {
        defer { beliefs.removeValue(forKey: id) }
        guard let belief = beliefs[id] else { return }
        if let call = belief.call {
            record(id, .closed(call: call, reason: .sessionRemoved))
        }
        guard belief.isWaiting else { return }
        record(id, .pushed(asserts: .absent, activity: nil, clients: clients))
    }

    private func closeReason(
        isWaiting: Bool, activity: String?, open: OpenPrompt?, refusal: String?
    ) -> PromptLifecycleRecord.CloseReason {
        guard isWaiting else { return .activity(activity) }
        if let open { return .superseded(call: open.callID) }
        return .unnamed(code: refusal ?? "-")
    }

    /// The Mac's own answer to "which dialog is up".
    ///
    /// `pushedOpenPrompt` and not `openPrompt`, because a log line must not build an agent's
    /// adapter to write itself — see that method for the side-effect rule, which the store's
    /// own per-tick derivation now leans on too.
    private func derive(_ id: UUID) -> Result<OpenPrompt, TimelineErrorCode> {
        prompts.pushedOpenPrompt(inSession: id)
    }

    private static func kind(of prompt: OpenPrompt) -> PromptLifecycleRecord.Kind {
        switch prompt {
        case .question(_, let questions): return .question(options: questions.map(\.options.count))
        case .permission(_, let tool, _): return .permission(tool: tool)
        }
    }

    /// What goes to the file and never to os_log: the words on the dialog.
    ///
    /// Bounded, because a tool summary is an arbitrary command line and a question is
    /// arbitrary prose. The cap is generous enough to identify a dialog against a screenshot
    /// and small enough that a day of them is still a file a person can read.
    private static func detail(of prompt: OpenPrompt) -> String? {
        let text: String?
        switch prompt {
        case .question(_, let questions):
            text = questions.map(\.question).joined(separator: " | ")
        case .permission(_, _, let summary):
            text = summary
        }
        guard let text, !text.isEmpty else { return nil }
        return text.count <= 240 ? text : String(text.prefix(240)) + "…"
    }

    private func record(
        _ session: UUID, _ event: PromptLifecycleRecord.Event, detail: String? = nil
    ) {
        record(PromptLifecycleRecord(session: session, event: event, detail: detail))
    }

    /// Filed through `PromptService`'s sink rather than a second one of this type's own, so a
    /// dialog's whole life — opened here, refused there — reads as one stream and a test
    /// substitutes one closure to see all of it. Read per record, never captured, so a seam
    /// installed after this object was built still takes effect.
    private func record(_ record: PromptLifecycleRecord) {
        prompts.lifecycleSink(record)
    }
}
