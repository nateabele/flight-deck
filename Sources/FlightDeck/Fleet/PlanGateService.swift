import FleetKit
import Foundation

/// Everything the Mac does about plan gates: find them, describe them, act on them.
///
/// **Polled rather than pushed, because there is nothing to push.** A blocking
/// `PermissionRequest` hook writes a registry file and then waits; nothing signals Flight
/// Deck. The poll is a directory read of a handful of small files, and the cost is bounded by
/// caching the plan per call id — see `planFetchCount` in the tests.
///
/// **The plan is fetched once per gate.** A gate can stay open for four days; the plan behind
/// one call id cannot change, because a revision is a *new* `ExitPlanMode` call with a new id.
@MainActor
final class PlanGateService {

    struct Gate {
        let entry: PlannotatorRegistry.Entry
        let callID: String
        let plan: String
        let blocks: PlanBlocks
        var annotationCount: Int
    }

    /// Test seams, in the shape `PromptService.tail` is one.
    var registryDirectory: URL = PlannotatorRegistry.defaultDirectory
    var isAlive: (pid_t) -> Bool = PlannotatorRegistry.processIsAlive
    var parentOf: (pid_t) -> pid_t? = PlannotatorRegistry.parentProcess
    var makeClient: (Int) -> PlanGateClient = { PlanGateClient(port: $0) }
    /// The `ExitPlanMode` call id for a session, from the transcript. Injected rather than
    /// reached for, so this class needs neither a store nor a pager.
    var callID: (UUID) -> String?
    /// The `claude` pid backing a session.
    var pid: (UUID) -> pid_t?
    /// Every session this Mac knows.
    var sessions: () -> [UUID]

    private var gates: [UUID: Gate] = [:]
    private var resolvedTokens: [UUID: [UUID]] = [:]

    init(callID: @escaping (UUID) -> String?,
         pid: @escaping (UUID) -> pid_t?,
         sessions: @escaping () -> [UUID]) {
        self.callID = callID
        self.pid = pid
        self.sessions = sessions
    }

    /// Re-read the registry. Gates that vanished are dropped; new ones have their plan
    /// fetched exactly once.
    func refresh() async {
        let live = PlannotatorRegistry.planGates(
            in: registryDirectory, isAlive: isAlive, parentOf: parentOf
        )
        var next: [UUID: Gate] = [:]
        for session in sessions() {
            guard let claudePID = pid(session), let entry = live[claudePID] else { continue }
            guard let call = callID(session) else { continue }
            // Already held, and the call has not moved: keep it, plan and all.
            if let existing = gates[session], existing.callID == call,
               existing.entry.pid == entry.pid {
                next[session] = existing
                continue
            }
            guard let plan = await makeClient(entry.port).plan() else { continue }
            next[session] = Gate(entry: entry, callID: call, plan: plan,
                                 blocks: PlanBlocks.split(plan), annotationCount: 0)
        }
        gates = next
    }

    func gate(for session: UUID) -> WirePlanGate? {
        guard let gate = gates[session] else { return nil }
        return WirePlanGate(
            callID: gate.callID, tier: "annotate", plan: gate.plan,
            startedAt: gate.entry.startedAt, annotationCount: gate.annotationCount
        )
    }

    /// Post one comment. `block` is resolved against **this** Mac's split of the plan.
    func annotate(
        session: UUID, call: String, text: String, block: Int?, token: UUID
    ) async -> Result<Void, TimelineErrorCode> {
        guard let gate = gates[session] else { return .failure("not_waiting") }
        guard gate.callID == call else { return .failure("prompt_changed") }

        var originalText: String?
        if let block {
            // Out of range is a refusal, not a silent downgrade: the phone drew a target this
            // Mac does not have, so the two disagree about the plan and nothing should pin.
            guard let resolved = gate.blocks.block(at: block) else {
                return .failure("unreadable_screen")
            }
            // A non-target IS a silent downgrade to global, deliberately: the phone should not
            // have offered a tap, but the reader's words are real and a global comment carries
            // them without pinning to an arbitrary copy.
            originalText = resolved.isTarget ? resolved.text : nil
        }

        let ok = await makeClient(gate.entry.port)
            .annotate(text: text, originalText: originalText)
        guard ok else { return .failure("unreadable_screen") }
        gates[session]?.annotationCount += 1
        return .success(())
    }

    /// Approve or request changes, once.
    func resolve(
        session: UUID, call: String, approve: Bool, feedback: String?, token: UUID
    ) async -> Result<Void, TimelineErrorCode> {
        // Before anything is sent, exactly as `answerPrompt`'s token test precedes any
        // keystroke: a retry resolves nothing twice.
        if resolvedTokens[session, default: []].contains(token) { return .success(()) }
        guard let gate = gates[session] else { return .failure("not_waiting") }
        guard gate.callID == call else { return .failure("prompt_changed") }

        resolvedTokens[session, default: []].append(token)
        let ok = await makeClient(gate.entry.port)
            .resolve(approved: approve, feedback: feedback)
        guard ok else {
            // The gate did not take it — let a retry through rather than swallowing the tap.
            resolvedTokens[session]?.removeAll { $0 == token }
            return .failure("unreadable_screen")
        }
        gates[session] = nil
        return .success(())
    }
}
