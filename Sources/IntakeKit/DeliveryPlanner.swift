import Foundation

/// A single side effect the app must carry out to tell a bead's current holder that an
/// intake release changed it. Pure data — `IntakeDelivery` (app side) is what actually
/// shells out or injects.
public enum DeliveryAction: Equatable, Sendable {
    case mail(to: String, bead: String, subject: String, body: String, urgent: Bool)
    case inject(agent: String, bead: String, text: String)
    case reclaim(bead: String, agent: String)

    /// String discriminator for tests that assert a *sequence* of action kinds
    /// (`a.map(\.kindName)`) without unpacking every associated value.
    public var kindName: String {
        switch self {
        case .mail: "mail"
        case .inject: "inject"
        case .reclaim: "reclaim"
        }
    }
}

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
                    actions.append(.reclaim(bead: id, agent: assignee))
                    actions.append(.inject(agent: assignee, bead: id, text: invalidatingInjectText(bead: id, reason: reason)))
                }
            }
            actions.append(.mail(
                to: assignee, bead: id,
                subject: subject(for: rating, bead: id),
                body: mailBody(for: rating, bead: id, reason: reason),
                urgent: rating == .invalidating))
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

    private static func subject(for rating: DeliveryRating, bead: String) -> String {
        "Flight Deck intake: \(bead) changed (\(label(rating)))"
    }

    private static func mailBody(for rating: DeliveryRating, bead: String, reason: String) -> String {
        switch rating {
        case .clarifying:
            "Flight Deck intake changed \(bead) (clarifying): \(reason). No action needed unless it changes your plan."
        case .scopeChange:
            "Flight Deck intake changed \(bead) while you were working on it (scope change): \(reason). A prompt has been sent to your session — run `br show \(bead)` to see the full change."
        case .invalidating:
            "Flight Deck intake changed \(bead) (invalidating): \(reason). The bead has been reclaimed and returned to open."
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
