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
    @MainActor
    static func snapshot(of store: SessionStore) -> FleetSnapshot {
        FleetSnapshot(projects: store.repos.map {
            project(
                $0, statuses: store.statuses, unread: store.unreadIdle,
                backgroundWork: store.backgroundWorkSessions
            )
        })
    }

    @MainActor
    static func project(
        _ repo: Repo, statuses: [UUID: SessionStatus], unread: Set<UUID>,
        backgroundWork: Set<UUID>
    ) -> WireProject {
        WireProject(
            id: repo.id,
            name: repo.displayName,
            path: repo.url.path,
            isCollapsed: repo.isCollapsed,
            sessions: repo.sessions.map {
                project(
                    $0, status: statuses[$0.id], unread: unread,
                    hasBackgroundWork: backgroundWork.contains($0.id)
                )
            }
        )
    }

    @MainActor
    static func project(
        _ session: Session, status: SessionStatus?, unread: Set<UUID>, hasBackgroundWork: Bool
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
            hasBackgroundWork: hasBackgroundWork
        )
    }
}
