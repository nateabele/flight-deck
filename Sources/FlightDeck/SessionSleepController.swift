import Foundation

struct SleepInputs {
    var candidates: () -> [UUID]
    var activity: (UUID) -> SessionActivity?     // nil => no live agent
    var selectedID: () -> UUID?
    var reportsBackgroundWork: (UUID) -> Bool
    var daemonPID: (UUID) -> pid_t?
}

@MainActor
final class SessionSleepController {
    private let policy: SleepPolicy
    private let daemonControl: DaemonControlling
    private let inspector: ProcessInspecting
    private let resolver: AgentGroupResolving
    private let inputs: SleepInputs
    private let tearDownSurface: (UUID) -> Void
    private let rebuildSurface: (UUID) -> Void
    /// Live Off switch: consulted on every `tick()`, not read once at construction — unlike
    /// `policy`'s threshold, flipping this in Preferences must take effect immediately rather
    /// than waiting for the next launch. Defaults to `{ true }` so every existing
    /// `SessionSleepController(...)` construction (this file's own tests included) keeps
    /// compiling unchanged.
    private let sleepEnabled: () -> Bool
    private let now: () -> Date

    /// The least time between two rounds of the *expensive* half of an evaluation — the
    /// pidfile read and the process-tree walk. The idle clock is still kept every tick, so a
    /// busy blip between rounds still resets it; only the lookups are spaced out. The idle
    /// threshold is minutes, so a few seconds here moves a sleep by at most that much.
    ///
    /// Exists because those lookups ran for every idle tab on every 500ms tick: ~5% of a core
    /// on the main thread with 78 tabs (measured 2026-10-05), nearly all of it for tabs whose
    /// agent has live children (MCP servers) and so could never sleep anyway. 0 — the default,
    /// and what this file's older tests construct — evaluates every tick.
    private let evaluationInterval: TimeInterval
    private var lastEvaluation: Date?

    private(set) var asleep: Set<UUID> = []
    private var idleSince: [UUID: Date] = [:]

    init(policy: SleepPolicy, daemonControl: DaemonControlling, inspector: ProcessInspecting,
         resolver: AgentGroupResolving, inputs: SleepInputs,
         tearDownSurface: @escaping (UUID) -> Void,
         rebuildSurface: @escaping (UUID) -> Void = { _ in },
         sleepEnabled: @escaping () -> Bool = { true },
         evaluationInterval: TimeInterval = 0, now: @escaping () -> Date) {
        self.policy = policy; self.daemonControl = daemonControl; self.inspector = inspector
        self.resolver = resolver; self.inputs = inputs
        self.tearDownSurface = tearDownSurface; self.rebuildSurface = rebuildSurface
        self.sleepEnabled = sleepEnabled; self.evaluationInterval = evaluationInterval
        self.now = now
    }

    func tick() {
        guard sleepEnabled() else { return }   // live Off gate
        let t = now()
        let candidates = inputs.candidates()
        let evaluate = lastEvaluation.map { t.timeIntervalSince($0) >= evaluationInterval } ?? true
        if evaluate { lastEvaluation = t }
        for id in candidates where !asleep.contains(id) {
            let activity: SessionActivity
            switch inputs.activity(id) {
            case let live? where live == .idle || live == .waiting:
                activity = live
                if idleSince[id] == nil { idleSince[id] = t }
            default:
                idleSince[id] = nil   // busy / no-agent clears the clock
                continue
            }
            guard evaluate else { continue }
            // Cheap gates first. The two expensive fields are filled with the values that
            // PASS their predicates, so this can only say "sleep" when every cheap predicate
            // already does; `SleepPolicy` requires all of them, so the real values can only
            // turn that into ineligible, never the other way. A tab that is selected, busy,
            // reporting work or not yet idle long enough costs no syscall at all.
            var candidate = SleepCandidate(
                id: id, activity: activity,
                isSelected: inputs.selectedID() == id,
                reportsBackgroundWork: inputs.reportsBackgroundWork(id),
                hasLiveDescendants: false,
                idleSince: idleSince[id],
                isDaemonized: true,
                isAsleep: false
            )
            guard policy.evaluate(candidate, now: t) == .sleep else { continue }
            let daemon = inputs.daemonPID(id)
            candidate.isDaemonized = daemon != nil
            candidate.hasLiveDescendants = daemon.map(hasLiveDescendants(daemon:)) ?? false
            if policy.evaluate(candidate, now: t) == .sleep { sleep(id) }
        }
        let known = Set(candidates)
        idleSince = idleSince.filter { known.contains($0.key) }   // forget vanished sessions
        asleep.formIntersection(known)   // forget sessions closed while asleep
    }

    /// Walk the AGENT tree (daemon's child), NOT the attach-client surface shell:
    /// under fd-abduco the tab's recorded shell is the thin attach-client; the agent
    /// and its background work live under the daemon's child.
    ///
    /// Takes the daemon pid rather than the session id so the pidfile `tick` just read is not
    /// read a second time here.
    private func hasLiveDescendants(daemon: pid_t) -> Bool {
        guard let pgid = resolver.agentProcessGroup(daemonPID: daemon) else { return false }
        return !inspector.descendants(of: pgid).isEmpty
    }

    private func sleep(_ id: UUID) {
        tearDownSurface(id)        // Axis B: drop the attach client (detach path)
        daemonControl.stop(id)     // Axis A: SIGSTOP the agent group
        asleep.insert(id)
        idleSince[id] = nil
    }

    /// Wake: CONT the agent first so it's running, then rebuild the surface so the
    /// daemon's ring replay restores the screen. Idempotent.
    func wake(_ id: UUID) {
        guard asleep.contains(id) else { return }
        daemonControl.cont(id)     // ensure the agent is running FIRST
        asleep.remove(id)
        rebuildSurface(id)         // then re-attach; the daemon's ring replay restores the screen
    }
}
