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
        // Read off the store's own preferences, for the same reason `planGates` defaults off
        // the store rather than being threaded by every caller: a call site that forgot the
        // parameter would otherwise project the gate as off even for a Mac that turned it on.
        let allowsBlockedAbort = store.preferences?.allowsBlockedPromptAbort ?? false
        return FleetSnapshot(projects: store.repos.map {
            project(
                $0, statuses: store.statuses, unread: store.unreadIdle,
                backgroundWork: store.backgroundWorkSessions,
                openPromptCalls: store.openPromptCalls,
                apiErrors: store.apiErrors,
                planGates: planGates,
                allowsBlockedAbort: allowsBlockedAbort,
                // The cache, never `IntakeService`: see `SessionStore.intakeSummaries` for why
                // the oracle must read exactly what the store last recorded.
                intakes: store.intakeSummaries[$0.id] ?? nil,
                swarm: store.swarmSummaries[$0.id] ?? nil,
                subagentTrees: store.subagentTrees,
                openPromptAgents: store.openPromptAgents,
                openPromptOffers: store.openPromptOffers
            )
        })
    }

    @MainActor
    static func project(
        _ repo: Repo, statuses: [UUID: SessionStatus], unread: Set<UUID>,
        backgroundWork: Set<UUID>, openPromptCalls: [UUID: String],
        apiErrors: [UUID: SessionAPIError],
        planGates: PlanGateService? = nil, allowsBlockedAbort: Bool = false,
        intakes: [WireIntakeSummary]? = nil,
        swarm: WireSwarm? = nil,
        subagentTrees: [UUID: SubagentTree] = [:],
        openPromptAgents: [UUID: String] = [:],
        openPromptOffers: [UUID: OpenPrompt] = [:]
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
                    apiError: apiErrors[$0.id],
                    planGates: planGates,
                    allowsBlockedAbort: allowsBlockedAbort,
                    subagents: subagentModel(of: $0, trees: subagentTrees, status: statuses[$0.id]),
                    openPromptAgent: openPromptAgents[$0.id],
                    openPrompt: openPromptOffers[$0.id]
                )
            },
            intakes: intakes,
            swarm: swarm
        )
    }

    @MainActor
    static func project(
        _ session: Session, status: SessionStatus?, unread: Set<UUID>,
        hasBackgroundWork: Bool, openPromptCall: String?,
        apiError: SessionAPIError?,
        planGates: PlanGateService? = nil, allowsBlockedAbort: Bool = false,
        subagents: SubagentTree? = nil, openPromptAgent: String? = nil,
        openPrompt: OpenPrompt? = nil
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
            openPromptCall: openPromptCall.map(OpenPromptIdentity.call) ?? .noPrompt,
            apiError: apiError,
            // A store-wide preference, not a per-session fact, but it rides on every session
            // because that is the shape a client reads: nothing else on the wire names "this
            // Mac" independent of a tab.
            allowsBlockedAbort: allowsBlockedAbort,
            answerless: status?.answerless ?? false,
            // A fact about this build: `SessionStore.answerPrompt` drives the row. It says
            // nothing about which agents raise questions — `OpenPrompt.find` decides that on
            // both ends, so a tab with no question card never reads it.
            acceptsTypedAnswers: true,
            subagents: subagents.map {
                wire($0, blocked: openPromptAgent, call: openPromptCall)
            },
            openPromptAgent: openPromptAgent,
            // Only for an agent whose transcript cannot carry the dialog — `SessionStore`
            // records no offer for any other — so a claude tab's bytes are unchanged.
            openPrompt: openPrompt.map(WireOpenPrompt.init)
        )
    }

    /// What a session's `subagents` field is built from. Claude gets a tree even when it is
    /// empty — `[]` on the wire says "this Mac models subagents and there are none", which a
    /// phone must be able to tell from a codex tab (nil: not modelled). Collapsing the two
    /// would hide a non-zero `subagentCount` behind an empty list on every codex tab.
    ///
    /// **No status, no tree** — still `[]`, never the stored tree. `applySubagents` emits only
    /// for a tab with a status (an event needs one to carry), and the tree now outlives a lost
    /// registry row; projecting it anyway made the snapshot disagree with what was emitted
    /// (`FleetReplicator`'s drift assertion) and showed a reconnecting phone a tree a
    /// connected one never got. When the status appears, `emitActivity` carries the tree.
    @MainActor
    static func subagentModel(
        of session: Session, trees: [UUID: SubagentTree], status: SessionStatus?
    ) -> SubagentTree? {
        guard session.agent == .claude else { return nil }
        guard status != nil else { return .empty }
        return trees[session.id] ?? .empty
    }

    /// The tree as the wire carries it, with the node that owns the open dialog marked
    /// `blocked`. Marked here rather than stored that way because the tree is rebuilt from
    /// files and knows nothing of the transcript call; `openPromptAgents` is what ties them.
    static func wire(_ tree: SubagentTree, blocked agent: String?, call: String?) -> [WireSubagent] {
        let marked = (agent != nil && call != nil) ? tree.marking(blocked: agent!, call: call!) : tree
        return marked.nodes.map { node in
            let state: String
            switch node.state {
            case .running: state = "running"
            case .blocked: state = "blocked"
            case .done: state = "done"
            }
            return WireSubagent(id: node.id, parent: node.parentID, type: node.type,
                                description: node.description, state: state)
        }
    }
}
