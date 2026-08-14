// Sources/FlightDeck/SurfaceProcessRegistry.swift
import Darwin
import Foundation
import OSLog

/// A session's shell.
///
/// Deliberately carries no `pgid`. An earlier version recorded one at creation time and both
/// `SessionStore.reapSession` and the launch sweep read it back; that number races the child's
/// own `setsid()` and, when the read wins, is Flight Deck's *own* group forever. Every signal
/// path now re-derives the group from the live process table right before it signals (see
/// `SessionStore.reapSession` and `sweepOrphans`), so there is no reader left and persisting
/// the number would only invite a future one. Old `sessions.json` files still carry a `pgid`
/// key; synthesized `Codable` ignores unknown keys, so they keep decoding.
struct SessionProcess: Codable, Equatable {
    let identity: ProcessIdentity
}

/// Remembers which process each tab owns.
///
/// **Why a diff and not an API call.** libghostty forks the shell somewhere inside surface
/// creation and exposes no pid for it — the only process-related export is
/// `ghostty_surface_process_exited` (`vendor/ghostty/include/ghostty.h:1082`). Patching the
/// vendored submodule to add one is not an option: it is pinned to upstream and
/// `scripts/build-libghostty.sh` `git clean`s it after every build. So we snapshot our own
/// children before creating the surface and watch for the one that appears afterwards.
///
/// **Why the watch is asynchronous.** The fork does *not* happen inside `ghostty_surface_new`.
/// `Surface.init` only spawns the IO thread (`vendor/ghostty/src/Surface.zig:709`); that thread
/// then runs `threadMain_` → `io.threadEnter` (`vendor/ghostty/src/termio/Thread.zig:267`) →
/// `Exec.threadEnter` → `subprocess.start` (`vendor/ghostty/src/termio/Exec.zig:84-91`), and
/// only there does it fork. A second `children(of:)` snapshot taken on the main thread the
/// microsecond `makeSurface` returns therefore usually sees *nothing*, which is exactly how
/// this feature came to be inert in the real app while every test stayed green. So `record`
/// takes the "before" snapshot, lets the caller create the surface, and then polls off the
/// synchronous path until the child shows up or the deadline expires.
///
/// **Why cross-assignment is the hazard that shapes the rest.** Several surfaces can be created
/// back to back (⌘N twice, or `restore()` rebuilding every tab in one synchronous loop), and
/// their forks land in whatever order the IO threads get scheduled — which is *not* guaranteed
/// to be creation order. Handing tab A the shell that actually belongs to tab B would make
/// closing A kill B's process tree: the one way this design can signal the wrong process, and
/// far worse than recording nothing. So a pid is claimed only when it can belong to exactly one
/// outstanding request (the sole-contender rule in `claimUnambiguousChildren` below). When two
/// requests could both own it, neither gets it, and the tab degrades to libghostty's SIGHUP-only
/// teardown — which is what every tab did before this feature existed.
///
/// **What the unattributable ones still get.** Two of the three teardown paths never needed the
/// per-tab mapping: app quit and the launch-time orphan sweep both mean "kill every shell this
/// run forked". So a child nobody could claim is still filed, under a key of its own, by
/// `adoptUnattributedChildren`. No tab close can reach it — that is the point — but quitting and
/// crash recovery do. Without this, restoring a window full of tabs (every surface created in
/// one synchronous loop, so nothing is individually attributable) would record nothing at all.
@MainActor
final class SurfaceProcessRegistry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "SurfaceProcessRegistry"
    )

    /// How long to wait for libghostty's IO thread to fork the shell. Generous next to the
    /// handful of milliseconds a `posix_spawn` off an already-running thread actually takes,
    /// but nothing waits on this — it runs in the background — so the cost of being patient is
    /// only that a doomed request lingers a little longer.
    static let pollInterval = 0.02
    /// `pollInterval × pollBudget` = 0.5 s. Counted in polls rather than accumulated seconds
    /// for the reason `SessionReaper.escalate` documents: an integer count cannot drift.
    static let pollBudget = 25

    /// One outstanding "which child did this surface fork?" question.
    ///
    /// A reference type because `claimUnambiguousChildren` settles these in place while
    /// iterating, and because it buckets candidates by contender *identity*.
    private final class Resolution {
        let tabID: UUID
        /// Our children at the instant *before* the surface was created. A pid in here predates
        /// this request and therefore cannot be its shell — which is also what makes a request
        /// stop being a contender for it.
        let before: Set<pid_t>
        var pollsLeft: Int
        /// Settled by claiming a pid. Distinct from `isFinished`: a request that gave up
        /// remains a *contender* (the pid it was waiting for may still be about to appear, and
        /// handing that pid to a sibling would be the cross-assignment this type exists to
        /// prevent), whereas a request that claimed one is out of contention for good.
        var hasClaimed = false
        /// No longer polling, for either reason.
        var isFinished = false

        init(tabID: UUID, before: Set<pid_t>, pollsLeft: Int) {
            self.tabID = tabID
            self.before = before
            self.pollsLeft = pollsLeft
        }
    }

    private let inspector: ProcessInspecting
    private let sleeper: ReaperSleeping
    private var processes: [UUID: SessionProcess] = [:]
    private var pending: [Resolution] = []
    private var isResolving = false

    /// Called once after each batch of resolutions settles, so the owner can persist what was
    /// learned. Records arrive up to half a second after the tab does, and a crash in between
    /// would otherwise leave the snapshot naming no shell for a tab that has one.
    var onChange: (() -> Void)?

    /// - Parameters:
    ///   - inspector: the process table to read. Injected so the whole resolution can be
    ///     driven from a scripted tree, with no real fork anywhere.
    ///   - sleeper: the poll delay, reusing the reaper's seam so a test gets the same
    ///     `InstantSleeper` treatment it already uses for the ladder.
    init(inspector: ProcessInspecting = ProcessTree(), sleeper: ReaperSleeping = RealSleeper()) {
        self.inspector = inspector
        self.sleeper = sleeper
    }

    var all: [UUID: SessionProcess] { processes }

    /// Runs `make`, then resolves whatever child it eventually forked, in the background.
    ///
    /// Returns as soon as `make` does — the resolution never blocks the main actor, and the
    /// record simply appears (or does not) a few polls later.
    ///
    /// A `nil` result means surface creation failed, so there is no IO thread and there will be
    /// no fork; no request is queued in that case. That is not just an optimization: it is what
    /// keeps every test whose stub provider returns `nil` from starting a background poll of the
    /// *test runner's* real process table and claiming some other test's child.
    @discardableResult
    func record<T>(for tabID: UUID, around make: () -> T?) -> T? {
        // Settle what is already resolvable *before* this request joins the contest. A tab
        // created while an earlier one's fork has already landed would otherwise become a
        // second contender for that pid and deadlock both of them — which is precisely the
        // shape `restore()` produces, rebuilding every tab in one synchronous loop.
        claimUnambiguousChildren()

        let before = inspector.children(of: getpid())
        let result = make()
        guard result != nil else { return nil }

        pending.append(Resolution(tabID: tabID, before: before, pollsLeft: Self.pollBudget))
        startResolving()
        return result
    }

    func process(for tabID: UUID) -> SessionProcess? { processes[tabID] }

    @discardableResult
    func forget(_ tabID: UUID) -> SessionProcess? { processes.removeValue(forKey: tabID) }

    /// Re-establishes (or refreshes) a single record without disturbing any other.
    ///
    /// Used by `SessionStore.sweepOrphans` to put a survivor it could not kill back where
    /// `persist()` can see it — the on-disk record is otherwise one-shot, since nothing but
    /// the sweep itself ever repopulates this registry from a previous run's snapshot, and a
    /// survivor the sweep failed to kill would vanish the moment anything else in the new run
    /// persisted. That caller passes a **fresh** `UUID`, not the survivor's old key: the old
    /// key names a tab this run has already recreated, and reusing it here would overwrite that
    /// live tab's real record with a dead run's orphan.
    func keep(_ tabID: UUID, as process: SessionProcess) { processes[tabID] = process }

    func restore(_ restored: [UUID: SessionProcess]) { processes = restored }

    // MARK: - Resolution

    /// One background loop for all outstanding requests, not one per request:
    /// `claimUnambiguousChildren` has to see every request at once to know whether a new pid has
    /// a sole contender.
    private func startResolving() {
        guard !isResolving else { return }
        isResolving = true
        Task { [weak self] in await self?.resolve() }
    }

    private func resolve() async {
        while pending.contains(where: { !$0.isFinished }) {
            await sleeper.sleep(seconds: Self.pollInterval)
            claimUnambiguousChildren()
            spendAPoll()
        }
        adoptUnattributedChildren()
        // Only once nothing is outstanding: a finished-but-unclaimed request stays in `pending`
        // until then, because it is still a contender for any pid that appears late.
        pending.removeAll()
        isResolving = false
        // Once per batch rather than once per claim: `persist()` re-encodes and atomically
        // rewrites the whole snapshot, and a burst like `restore()` would otherwise do that
        // eighteen times in half a second for no benefit.
        onChange?()
    }

    /// Hand out every new pid that can only have come from one outstanding request.
    ///
    /// The contender rule *is* the safety property. A pid in a request's `before` set predates
    /// that request and so cannot be its shell; a request that has already claimed something is
    /// out of the running. Everything left is a genuine "could be either" — and a genuine
    /// "could be either" is never assigned to anybody.
    ///
    /// Dropping a *given-up* request from contention would be unsound in a way dropping a
    /// claimed one is not: its fork may still be about to appear, and handing that late pid to
    /// a sibling is exactly the cross-assignment this guards. So `hasClaimed`, not
    /// `isFinished`, is what removes a request from the contest.
    private func claimUnambiguousChildren() {
        guard !pending.isEmpty else { return }
        let recorded = Set(processes.values.map(\.identity.pid))
        let candidates = inspector.children(of: getpid()).subtracting(recorded)

        // Bucketed from a single consistent view of the table, before any claim mutates the
        // contender sets. A claim that narrows some other pid's contenders down to one is
        // simply picked up on the next poll.
        var exclusive: [ObjectIdentifier: [pid_t]] = [:]
        for pid in candidates {
            let contenders = pending.filter { !$0.hasClaimed && !$0.before.contains(pid) }
            guard contenders.count == 1, let sole = contenders.first else { continue }
            exclusive[ObjectIdentifier(sole), default: []].append(pid)
        }

        for resolution in pending where !resolution.isFinished {
            let mine = exclusive[ObjectIdentifier(resolution)] ?? []
            if mine.count == 1, let pid = mine.first {
                claim(pid, for: resolution)
            } else if mine.count > 1 {
                // Surface creation forks exactly one child, so two pids that could only have
                // come from this request means the process table is telling us something we do
                // not understand. Same conservatism as the original synchronous diff.
                finish(
                    resolution,
                    warning: "expected 1 new child, \(mine.count) are attributable to this tab"
                )
            }
        }
    }

    /// Charges one poll against every request still waiting, and gives up on the ones that have
    /// run out. Separate from the claiming pass so that `record`'s opportunistic claim does not
    /// also eat somebody else's budget — `restore()` calls it once per tab.
    private func spendAPoll() {
        for resolution in pending where !resolution.isFinished {
            resolution.pollsLeft -= 1
            if resolution.pollsLeft <= 0 {
                finish(
                    resolution,
                    warning: "no new child appeared within \(Self.pollBudget) polls, "
                        + "or another tab could equally have owned the one that did"
                )
            }
        }
    }

    /// Files every child this batch produced that no single tab could claim, under keys of its
    /// own.
    ///
    /// **Why this is not a loophole in the claim rule.** These records are deliberately *not*
    /// keyed by any tab: `closeSession` looks a tab up by its own id and will never find one,
    /// so no tab close can signal a process this registry could not attribute to it. What they
    /// do reach is the two teardown paths that never needed the mapping in the first place —
    /// app quit (`reapAllForQuit` walks `all`) and the next launch's orphan sweep (they are
    /// persisted). Both mean "kill every shell this run forked", which is exactly what these
    /// are, and both are identity-gated like everything else.
    ///
    /// **Why it matters.** Restoring a window full of tabs creates every surface in one
    /// synchronous loop, so every request is outstanding before any fork lands and *nothing* is
    /// individually attributable — verified against a real 18-tab restore, where the strict rule
    /// alone recorded zero of eighteen shells and quitting would have leaked all of them. Under
    /// this, a tab close still degrades to libghostty's SIGHUP-only teardown for those tabs, but
    /// quitting and crash recovery cover the whole set.
    ///
    /// The candidate set is exactly right because Flight Deck forks nothing else: every direct
    /// child it has ever had is a surface's shell. Anything that changes must revisit this.
    private func adoptUnattributedChildren() {
        let recorded = Set(processes.values.map(\.identity.pid))
        for pid in inspector.children(of: getpid()).subtracting(recorded) {
            // Appeared after at least one of this batch's requests started, so it is one of
            // their forks. A pid predating every request in the batch is somebody else's
            // problem and is left alone.
            guard pending.contains(where: { !$0.before.contains(pid) }) else { continue }
            guard let start = inspector.startTime(of: pid) else { continue }
            processes[UUID()] = SessionProcess(
                identity: ProcessIdentity(pid: pid, procStart: start)
            )
        }
    }

    private func claim(_ pid: pid_t, for resolution: Resolution) {
        // A start time is required, not optional: it is the entire identity gate. A child that
        // died between the listing and this read simply leaves the request polling — it will
        // not be a candidate again.
        guard let start = inspector.startTime(of: pid) else { return }

        processes[resolution.tabID] = SessionProcess(
            identity: ProcessIdentity(pid: pid, procStart: start)
        )
        resolution.hasClaimed = true
        resolution.isFinished = true
    }

    private func finish(_ resolution: Resolution, warning: String) {
        resolution.isFinished = true
        Self.logger.warning(
            "no shell recorded for tab: \(warning). This tab falls back to libghostty's SIGHUP-only teardown."
        )
    }
}
