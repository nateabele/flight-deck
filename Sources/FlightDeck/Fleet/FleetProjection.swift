import FleetKit
import Foundation

/// Reads the store into the wire's shape.
///
/// Two jobs, and the second is the one that pays for the first being pure: it builds the
/// snapshot a client gets at connect time, and it is the **oracle** `FleetReplicator`
/// compares its event-fold mirror against on every batch (see that type, and
/// specs/2026-08-18-fleet-state-encapsulation-design.md §4). Nothing here may mutate,
/// publish, or memoize — an assertion that changed the thing it was asserting about would be
/// worse than no assertion.
enum FleetProjection {
    /// **`planGates` defaults to the store's own, and that default is what makes the drift
    /// assertion trustworthy.** Every other field here is read off `store`; when this one had
    /// to be threaded in by hand, an oracle built by a caller that forgot it projected
    /// `planGate: nil` for a session whose gate the event-fold mirror had already folded — so
    /// any store test that attached `attachedReplicator` and opened a gate failed with a
    /// *false* drift report, and the plan-gate integration tests had to route around the real
    /// harness to stay green. Reading it off the store closes that whole class: a call site can
    /// no longer forget. Passing a service explicitly still wins, and passing none for a store
    /// that has none still projects no gates, exactly as before.
    @MainActor
    static func snapshot(of store: SessionStore, planGates: PlanGateService? = nil) -> FleetSnapshot {
        let planGates = planGates ?? store.planGates
        return FleetSnapshot(projects: store.repos.map {
            project(
                $0, statuses: store.statuses, unread: store.unreadIdle,
                backgroundWork: store.backgroundWorkSessions,
                openPromptCalls: store.openPromptCalls,
                planGates: planGates
            )
        })
    }

    @MainActor
    static func project(
        _ repo: Repo, statuses: [UUID: SessionStatus], unread: Set<UUID>,
        backgroundWork: Set<UUID>, openPromptCalls: [UUID: String],
        planGates: PlanGateService? = nil
    ) -> WireProject {
        WireProject(
            id: repo.id,
            name: repo.displayName,
            path: repo.url.path,
            isCollapsed: repo.isCollapsed,
            sessions: repo.sessions.map {
                project(
                    $0, status: statuses[$0.id], unread: unread,
                    hasBackgroundWork: backgroundWork.contains($0.id),
                    openPromptCall: openPromptCalls[$0.id],
                    planGates: planGates
                )
            }
        )
    }

    @MainActor
    static func project(
        _ session: Session, status: SessionStatus?, unread: Set<UUID>,
        hasBackgroundWork: Bool, openPromptCall: String?,
        planGates: PlanGateService? = nil
    ) -> WireSession {
        WireSession(
            id: session.id,
            title: session.title,
            agent: session.agent.rawValue,
            // `nil` deliberately, not `"idle"`: absence of a status means no agent process
            // is registered for this tab, which renders as nothing rather than as a dot.
            activity: status?.activity.rawValue,
            waitingFor: status?.waitingFor,
            subagentCount: status?.subagentCount ?? 0,
            isUnread: unread.contains(session.id),
            hasBackgroundWork: hasBackgroundWork,
            // `nil` when no `PlanGateService` was threaded in — a projection built in a test
            // with no service must still produce a `WireSession`, exactly as one with no
            // status must.
            planGate: planGates?.gate(for: session.id),
            // Never `.unreported`: this build always looks, so "no entry" is this Mac saying
            // it can name no open dialog — which is the assertion that retires a phone's card.
            // `.unreported` is reserved for a peer that predates the field.
            openPromptCall: openPromptCall.map(OpenPromptIdentity.call) ?? .noPrompt
        )
    }
}
