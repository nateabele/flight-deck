import Foundation

/// A single side effect the app must carry out to tell a bead's current holder that an
/// intake release changed it. Pure data — `IntakeDelivery` (app side) is what actually
/// shells out or injects.
public enum DeliveryAction: Equatable, Sendable {
    /// Carries the rating and reason, not a finished body: the body says what Flight Deck did
    /// for the holder (prompt sent, bead reclaimed), and only `IntakeDelivery` knows whether
    /// the `inject`/`reclaim` before it actually worked. A body fixed here would tell a holder
    /// their bead "has been reclaimed" after the `br update` behind that claim failed.
    case mail(to: String, bead: String, rating: DeliveryRating, reason: String)
    case inject(agent: String, bead: String, text: String)
    /// `reason` rides along so `IntakeDelivery` can build a correct stop-work notice at
    /// delivery time if the live `br update` this implies turns out to fail — it has no
    /// other way to recover the original `Delivery.reason` for that bead.
    case reclaim(bead: String, agent: String, reason: String)

    /// String discriminator for tests that assert a *sequence* of action kinds
    /// (`a.map(\.kindName)`) without unpacking every associated value.
    public var kindName: String {
        switch self {
        case .mail: "mail"
        case .inject: "inject"
        case .reclaim: "reclaim"
        }
    }

    /// What the release review calls this action (spec §2 — the human never reads the engine's
    /// own words: "inject" is plumbing, and a reclaim is the task taken back off its holder).
    public var displayName: String {
        switch self {
        case .mail: "mail"
        case .inject: "session message"
        case .reclaim: "task taken back"
        }
    }
}

/// What became of the side effect a mail body describes — the `inject` for a scope change,
/// the `reclaim` for an invalidating edit. `notAttempted` is a holder with no FD session,
/// where the planner never emitted one.
public enum DeliveryOutcome: Equatable, Sendable { case notAttempted, succeeded, failed }

/// Turns a released `ChangeSet` into the notifications its affected beads' holders need,
/// graded by how much the change matters. `ratings` is the *final* rating per edit-op
/// index — the agent's own `Delivery.rating` with any user override already folded in —
/// so this never re-derives it from `op.delivery` itself.
public enum DeliveryPlanner {
    public static func plan(
        _ changeSet: ChangeSet,
        ratings: [Int: DeliveryRating],
        hasSession: (String) -> Bool
    ) -> [DeliveryAction] {
        var actions: [DeliveryAction] = []
        for (i, op) in changeSet.ops.enumerated() {
            // Only an editBead in flight has someone actively holding it to warn —
            // a bead that's still open, closed, or blocked has no session to interrupt.
            guard case .editBead(let id, _, let pre, let delivery) = op,
                  pre.status == "in_progress",
                  let assignee = pre.assignee,
                  let rating = ratings[i] ?? delivery?.rating
            else { continue }

            let reason = delivery?.reason ?? ""
            // No FD session means no way to inject or safely reassign the bead out from
            // under whoever holds it — mail is the only channel left, at any rating.
            if hasSession(assignee) {
                switch rating {
                case .clarifying: break
                case .scopeChange:
                    actions.append(.inject(agent: assignee, bead: id, text: scopeChangeInjectText(bead: id, reason: reason)))
                case .invalidating:
                    actions.append(.reclaim(bead: id, agent: assignee, reason: reason))
                    actions.append(.inject(agent: assignee, bead: id, text: invalidatingInjectText(bead: id, reason: reason)))
                }
            }
            // Always after this bead's inject/reclaim: `IntakeDelivery` words the mail from
            // how those went, so they must already have run when it gets here.
            actions.append(.mail(to: assignee, bead: id, rating: rating, reason: reason))
        }
        return actions
    }

    private static func label(_ rating: DeliveryRating) -> String {
        switch rating {
        case .clarifying: "clarifying"
        case .scopeChange: "scope change"
        case .invalidating: "invalidating"
        }
    }

    public static func subject(for rating: DeliveryRating, bead: String) -> String {
        "Flight Deck intake: \(bead) changed (\(label(rating)))"
    }

    /// Mail for an invalidating edit is sent with high importance and a required ack — the
    /// holder has to stop, not just read it eventually.
    public static func isUrgent(_ rating: DeliveryRating) -> Bool { rating == .invalidating }

    /// Every rating's body names the bead, the reason, and gives the reader somewhere to go
    /// (`br show` + the Agent Mail thread) — `outcome` gates only the sentence describing
    /// what Flight Deck actually *did*, so a holder is never told a prompt was sent or a
    /// reclaim happened when it was not attempted or did not work.
    public static func mailBody(for rating: DeliveryRating, bead: String, reason: String, outcome: DeliveryOutcome) -> String {
        let trailer = "Run `br show \(bead)` to see the full change, or reply on the Agent Mail thread bead:\(bead)."
        switch rating {
        case .clarifying:
            return "Flight Deck intake changed \(bead) (clarifying): \(reason). No action needed unless it changes your plan. \(trailer)"
        case .scopeChange:
            let didWhat = switch outcome {
            case .succeeded: "A prompt has been sent to your session."
            case .notAttempted: "You have no active Flight Deck session, so no prompt was sent."
            case .failed: "Flight Deck could not send a prompt to your session, so this mail is the only notice."
            }
            return "Flight Deck intake changed \(bead) (scope change) while you were working on it: \(reason). \(didWhat) \(trailer)"
        case .invalidating:
            let didWhat = outcome == .succeeded
                ? "It has been reclaimed and returned to open."
                : "Flight Deck could not reclaim it for you — set it back to open yourself (`br update \(bead) --status open --assignee \"\"`)."
            return "Stop work on \(bead) (invalidating): \(reason). \(didWhat) \(trailer)"
        }
    }

    private static func scopeChangeInjectText(bead: String, reason: String) -> String {
        "Flight Deck intake changed \(bead) while you are working on it (scope change): \(reason). " +
        "Run `br show \(bead)`, compare it with what you have done, and adjust — " +
        "or reply on the Agent Mail thread bead:\(bead) explaining why not."
    }

    private static func invalidatingInjectText(bead: String, reason: String) -> String {
        "Stop work on \(bead): \(reason). It has been reclaimed and returned to open."
    }
}
