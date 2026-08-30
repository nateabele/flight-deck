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
    /// Call ids this Mac has already resolved. The Plannotator hook sleeps for a beat before
    /// its server stops, so the registry file backing a gate we just resolved can outlive the
    /// resolve by ~1.5s — long enough for the next poll to see it as still open. A tombstone
    /// stops that poll from re-fetching a plan and re-opening a gate the phone already closed.
    private var resolvedCallIDs: Set<String> = []
    /// Single-flight guard: two overlapping `refresh()` calls (a slow poll and the next timer
    /// firing before it returns) must not both decide the same new gate needs fetching. The
    /// second call is dropped rather than queued — the next timer tick will simply try again.
    private var isRefreshing = false

    init(callID: @escaping (UUID) -> String?,
         pid: @escaping (UUID) -> pid_t?,
         sessions: @escaping () -> [UUID]) {
        self.callID = callID
        self.pid = pid
        self.sessions = sessions
    }

    /// Re-read the registry. Gates that vanished are dropped; new ones have their plan
    /// fetched exactly once.
    ///
    /// This class is reentrant during the `await` below — an `annotate` or `resolve` call for
    /// a session this refresh already decided to keep can run while a *different* session's
    /// plan is still being fetched. So gates that need no fetch are never touched, and each
    /// freshly-fetched gate is written into `gates` one key at a time as its fetch completes,
    /// rather than assembled into a separate dictionary and swapped in at the end — a wholesale
    /// swap would silently undo whatever `annotate`/`resolve` mutated on another session while
    /// this refresh was suspended fetching.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let live = PlannotatorRegistry.planGates(
            in: registryDirectory, isAlive: isAlive, parentOf: parentOf
        )

        var toFetch: [(session: UUID, entry: PlannotatorRegistry.Entry, call: String)] = []
        var keep: Set<UUID> = []

        for session in sessions() {
            guard let claudePID = pid(session), let entry = live[claudePID] else { continue }
            guard let call = callID(session) else { continue }
            // Resolved and tombstoned: do not resurrect it just because the registry file is
            // still on disk.
            if resolvedCallIDs.contains(call) { continue }
            // Already held, and the call has not moved: keep it, plan and all — no fetch, no
            // touch, so nothing here can race a concurrent mutation on this session.
            if let existing = gates[session], existing.callID == call,
               existing.entry.pid == entry.pid {
                keep.insert(session)
                continue
            }
            toFetch.append((session, entry, call))
        }

        // Drop gates for sessions no longer live or eligible. This runs before any `await`
        // below, so it is atomic with the scan above and cannot race a concurrent mutation.
        let wanted = keep.union(toFetch.map(\.session))
        for session in gates.keys where !wanted.contains(session) {
            gates[session] = nil
        }

        for (session, entry, call) in toFetch {
            // A session lands here either brand new (nothing to clear) or because its call
            // id/pid moved on from what `gates[session]` still holds — a superseded gate. On
            // any failure below, that old entry must not keep being projected as though it
            // were still the live one: clear it rather than `continue` past it.
            guard let plan = await makeClient(entry.port).plan() else {
                gates[session] = nil
                continue
            }
            // Re-check after the await: this call may have been resolved (and tombstoned)
            // while its plan was in flight. Same reasoning — whatever is in `gates[session]`
            // is stale either way, so clear it rather than leave it standing.
            if resolvedCallIDs.contains(call) {
                gates[session] = nil
                continue
            }
            gates[session] = Gate(entry: entry, callID: call, plan: plan,
                                 blocks: PlanBlocks.split(plan), annotationCount: 0)
        }
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
        // Tombstone the call id so a later poll — landing before the Plannotator hook's
        // registry file is actually removed — cannot resurrect what the phone just resolved.
        resolvedCallIDs.insert(call)
        return .success(())
    }
}
