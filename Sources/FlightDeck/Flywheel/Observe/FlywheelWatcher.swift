import Foundation

/// mtime-gates a coalesced re-poll of the two live `FlywheelReadCommands` lanes
/// (`agents`, `inProgressBeads`) for one project's Observe tab.
///
/// Mirrors `SessionStatusWatcher`: `WatchClock`-registered rather than owning a timer,
/// `nil` clock in tests that drive `drain()` directly. Polling rather than a vnode watch
/// for the same class of reason that watcher documents — cheap and uniform beats a
/// per-path kqueue registration for files that are written elsewhere (`am`/`br`, not this
/// process) and whose staleness tolerance is "within a beat or two", not "instantly".
///
/// **Why mtime-gate at all, rather than just re-shelling on every tick.** The two lanes
/// are cheap individually, but Observe can have several project tabs open at once, each
/// with its own watcher on the shared clock — an untargeted poll would multiply `am`/`br`
/// spawns by tab count on every single beat regardless of whether anything changed. A
/// `stat` per watched path is orders of magnitude cheaper than a process spawn, so `drain()`
/// pays that cost every tick and reserves the subprocess cost for a tick that actually
/// found a moved mtime.
@MainActor
final class FlywheelWatcher {
    private let project: String
    private let watchPaths: [URL]
    private let reads: FlywheelReadCommands
    private let debounce: Duration
    private let onChange: (FlywheelSnapshot) -> Void

    /// The clock this watcher is registered with, if any. Nil in tests, which call
    /// `drain()`/`repollNow()` directly.
    private weak var clock: WatchClock?

    /// Last mtime seen per watched path index. A path with no readable mtime (the store
    /// doesn't exist yet) reads as `nil` and is treated as "unchanged" — see `drain()`.
    private var mtimes: [URL: Date] = [:]

    /// Coalesces a burst of `drain()` calls into one repoll — the `SearchModel.swift`
    /// cancel-before-sleep idiom. Re-armed on every mtime move; only the last one in a
    /// burst survives to fire.
    private var debounceTask: Task<Void, Never>?

    /// Guards against a repoll still in flight when another one is requested (a burst that
    /// outlasts the debounce window, or `repollNow()` called directly while a scheduled one
    /// is running). Same guard shape as `TranscriptWatcher.poll()`.
    private var isPolling = false

    init(
        project: String,
        watchPaths: [URL],
        reads: FlywheelReadCommands,
        clock: WatchClock? = nil,
        debounce: Duration = .milliseconds(200),
        onChange: @escaping (FlywheelSnapshot) -> Void
    ) {
        self.project = project
        self.watchPaths = watchPaths
        self.reads = reads
        self.clock = clock
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Registers with the shared clock. This type owns no timer of its own — see
    /// `WatchClock` for why every poll in the app shares one.
    func start() {
        clock?.add(self) { [weak self] in self?.drain() }
    }

    func stop() {
        clock?.remove(self)
        debounceTask?.cancel()
    }

    /// One scheduled beat: a `stat` per watched path, no subprocess unless something moved.
    /// Synchronous so tests need no expectations — same shape as `SessionStatusWatcher.drain()`.
    func drain() {
        var changed = false
        for url in watchPaths {
            // `resourceValues` rather than `attributesOfItem`, same reasoning as
            // `SessionStatusWatcher`: one date out of a dictionary the file system would
            // otherwise build in full, and this runs per path per tick.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // A nil mtime means the store doesn't exist yet (not-yet-created beads.db, a
            // project that hasn't run `am`/`br` once) — treated as "unchanged" so a tab
            // watching a store that never materializes doesn't thrash a repoll every beat.
            guard let mtime else { continue }
            if mtimes[url] != mtime {
                mtimes[url] = mtime
                changed = true
            }
        }
        if changed {
            scheduleRepoll()
        }
    }

    /// Snapshots every watched path's current mtime into the gate without comparing against
    /// what was there before. `repollNow()` calls this once its reads land, so an unconditional
    /// poll (the `start()`/focus prime, or one this method's own debounce just fired) also
    /// establishes the gate's baseline — otherwise the *next* `drain()` would see an empty
    /// cache against a real mtime, read that as "moved", and fire a second, redundant repoll
    /// for data the prime just fetched.
    private func recordBaselineMtimes() {
        for url in watchPaths {
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                mtimes[url] = mtime
            }
        }
    }

    /// Cancel-before-sleep debounce: a burst of `drain()` calls arms this repeatedly, and
    /// only the last arm survives its sleep uncancelled — `SearchModel.swift:92-123`'s idiom,
    /// which is what collapses N mtime moves in a window into exactly one repoll.
    private func scheduleRepoll() {
        debounceTask?.cancel()
        let debounce = self.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.repollNow()
        }
    }

    /// Bypasses the mtime gate and shells out unconditionally — used to prime the first
    /// snapshot on `start()`/tab focus, and by `scheduleRepoll()` once the debounce settles.
    /// Only two lanes are live (`agents`, `inProgressBeads`); `reservations`/`depEdges`/
    /// `events` stay Task 2 nil-stubs that never touch the runner, so this is always exactly
    /// two shell-outs, not five.
    func repollNow() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        async let agents = reads.agents(project: project)
        async let beads = reads.inProgressBeads(project: project)
        let snapshot = await FlywheelSnapshot(
            agents: agents, beads: beads, reservations: nil, depEdges: nil, events: nil
        )
        recordBaselineMtimes()
        onChange(snapshot)
    }
}
