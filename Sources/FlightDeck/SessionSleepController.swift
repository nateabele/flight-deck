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

    private(set) var asleep: Set<UUID> = []
    private var idleSince: [UUID: Date] = [:]

    init(policy: SleepPolicy, daemonControl: DaemonControlling, inspector: ProcessInspecting,
         resolver: AgentGroupResolving, inputs: SleepInputs,
         tearDownSurface: @escaping (UUID) -> Void,
         rebuildSurface: @escaping (UUID) -> Void = { _ in },
         sleepEnabled: @escaping () -> Bool = { true }, now: @escaping () -> Date) {
        self.policy = policy; self.daemonControl = daemonControl; self.inspector = inspector
        self.resolver = resolver; self.inputs = inputs
        self.tearDownSurface = tearDownSurface; self.rebuildSurface = rebuildSurface
        self.sleepEnabled = sleepEnabled; self.now = now
    }

    func tick() {
        guard sleepEnabled() else { return }   // live Off gate
        let t = now()
        for id in inputs.candidates() where !asleep.contains(id) {
            let activity = inputs.activity(id)
            if activity == .idle || activity == .waiting {
                if idleSince[id] == nil { idleSince[id] = t }
            } else {
                idleSince[id] = nil   // busy / no-agent clears the clock
                continue
            }
            let candidate = SleepCandidate(
                id: id, activity: activity!,
                isSelected: inputs.selectedID() == id,
                reportsBackgroundWork: inputs.reportsBackgroundWork(id),
                hasLiveDescendants: hasLiveDescendants(id),
                idleSince: idleSince[id],
                isDaemonized: inputs.daemonPID(id) != nil,
                isAsleep: false
            )
            if policy.evaluate(candidate, now: t) == .sleep { sleep(id) }
        }
        let known = Set(inputs.candidates())
        idleSince = idleSince.filter { known.contains($0.key) }   // forget vanished sessions
    }

    /// Walk the AGENT tree (daemon's child), NOT the attach-client surface shell:
    /// under fd-abduco the tab's recorded shell is the thin attach-client; the agent
    /// and its background work live under the daemon's child.
    private func hasLiveDescendants(_ id: UUID) -> Bool {
        guard let daemon = inputs.daemonPID(id),
              let pgid = resolver.agentProcessGroup(daemonPID: daemon) else { return false }
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
