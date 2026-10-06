import Foundation

/// The `@MainActor` lifecycle owner `SessionStore` holds for Observe. Keeps one
/// `FlywheelWatcher` and one `FlywheelProjection` per enabled project, keyed by
/// standardized path; starts/tears down watchers on enable/disable and recomputes the
/// projection on each poll. Constructed lazily by whatever holds it — a fleet with no
/// enabled projects never builds a watcher, since `enable` is the only thing that does.
@MainActor
final class FlywheelObserveService: ObservableObject {
    private let reads: FlywheelReadCommands
    private let clock: WatchClock?
    private let stallThreshold: TimeInterval
    private let now: () -> Date

    private var watchers: [String: FlywheelWatcher] = [:]

    @Published private(set) var projections: [String: FlywheelProjection] = [:]

    /// Fired whenever a poll lands a new projection for any enabled project — the
    /// fleet-wide notifier hook (distinct from `@Published projections`, which drives
    /// SwiftUI observation directly).
    var onProjectionsChanged: (([String: FlywheelProjection]) -> Void)?
    /// Adds what Observe cannot read itself — guard-block waiters, tab activity, BLOCKED:
    /// declarations — before the projection is computed. Set by `SessionStore` (L3-S).
    var enrich: ((String, FlywheelSnapshot) -> FlywheelSnapshot)?

    init(reads: FlywheelReadCommands = FlywheelReadCommands(), clock: WatchClock? = nil,
         stallThreshold: TimeInterval = 600, now: @escaping () -> Date = Date.init) {
        self.reads = reads
        self.clock = clock
        self.stallThreshold = stallThreshold
        self.now = now
    }

    /// Mirrors `PreferencesStore.key` (that one is `private static`, so this replicates
    /// its body verbatim rather than calling it) — the same standardization
    /// `SessionStore.indexOfRepo` relies on, so a project key is stable regardless of a
    /// trailing slash or a non-canonical path spelling.
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Idempotent: a second `enable` for an already-watched project is a no-op, so a
    /// caller doesn't need to track whether it already enabled a given path.
    func enable(project path: String, watchPaths: [URL]) {
        let key = Self.key(path)
        guard watchers[key] == nil else { return }

        let watcher = FlywheelWatcher(project: path, watchPaths: watchPaths, reads: reads,
                                       clock: clock) { [weak self] snapshot in
            // `disable(project:)` stops the watcher but cannot cancel a priming
            // `repollNow()` already in flight (its subprocess round-trip is a real async
            // gap `stop()` has no visibility into) — a repoll that lands after disable
            // must not resurrect a torn-down projection. `watchers[key]` is the liveness
            // source of truth: once `disable` has run, the entry is gone and this closure
            // drops the late result instead of writing it back into the maps.
            guard let self, self.watchers[key] != nil else { return }
            let enriched = self.enrich?(key, snapshot) ?? snapshot
            let projection = FlywheelProjection.project(enriched, now: self.now(),
                                                          stallThreshold: self.stallThreshold,
                                                          previous: self.projections[key])
            self.projections[key] = projection
            self.onProjectionsChanged?(self.projections)
        }
        watchers[key] = watcher
        watcher.start()
        // Priming poll: `enable` stays synchronous (callers don't await it), but
        // `repollNow()` is async — fire-and-forget on the main actor so an enabled
        // project gets a first projection shortly after enable rather than waiting for
        // the clock's next scheduled beat.
        Task { await watcher.repollNow() }
    }

    /// Stops the watcher and drops both map entries, so `projection(forProject:)` reads
    /// `nil` immediately after — no stale projection lingers for a disabled project.
    func disable(project path: String) {
        let key = Self.key(path)
        watchers[key]?.stop()
        watchers[key] = nil
        projections[key] = nil
    }

    func projection(forProject path: String) -> FlywheelProjection? {
        projections[Self.key(path)]
    }
}
