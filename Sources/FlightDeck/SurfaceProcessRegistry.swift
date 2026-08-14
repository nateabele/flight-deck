// Sources/FlightDeck/SurfaceProcessRegistry.swift
import Darwin
import Foundation
import OSLog

/// A session's shell, plus the group to signal for it.
struct SessionProcess: Codable, Equatable {
    let identity: ProcessIdentity
    let pgid: pid_t
}

/// Remembers which process each tab owns.
///
/// **Why a diff and not an API call.** libghostty forks the shell inside
/// `ghostty_surface_new` and exposes no pid for it — the only process-related export is
/// `ghostty_surface_process_exited` (`vendor/ghostty/include/ghostty.h:1082`). Patching the
/// vendored submodule to add one is not an option: it is pinned to upstream and
/// `scripts/build-libghostty.sh` `git clean`s it after every build. So we bracket the call
/// and take the difference.
///
/// **Why that is sound.** Surface creation is `@MainActor` and therefore serialized, so
/// exactly one fork happens between the two snapshots. When it does not — zero new children,
/// or more than one — we record nothing at all. A tab with no record degrades to libghostty's
/// own SIGHUP-only teardown, which is what every tab does today; a *wrong* record would send
/// SIGKILL to an unrelated process.
@MainActor
final class SurfaceProcessRegistry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "SurfaceProcessRegistry"
    )

    private let inspector: ProcessInspecting
    private var processes: [UUID: SessionProcess] = [:]

    init(inspector: ProcessInspecting = ProcessTree()) {
        self.inspector = inspector
    }

    var all: [UUID: SessionProcess] { processes }

    /// Runs `make`, recording whatever child it forked.
    @discardableResult
    func record<T>(for tabID: UUID, around make: () -> T) -> T {
        let before = inspector.children(of: getpid())
        let result = make()
        let after = inspector.children(of: getpid())

        let new = after.subtracting(before)
        guard new.count == 1, let pid = new.first else {
            Self.logger.warning(
                "no shell recorded for tab: expected 1 new child, saw \(new.count). This tab falls back to libghostty's SIGHUP-only teardown."
            )
            return result
        }
        guard let start = inspector.startTime(of: pid) else { return result }

        // The shell calls setsid, so its group is its own — but read it through the seam
        // rather than assume, and fall back to the pid if the read fails. Going through
        // `inspector` rather than calling `getpgid` directly is what makes this testable.
        processes[tabID] = SessionProcess(
            identity: ProcessIdentity(pid: pid, procStart: start),
            pgid: inspector.pgid(of: pid) ?? pid
        )
        return result
    }

    func process(for tabID: UUID) -> SessionProcess? { processes[tabID] }

    @discardableResult
    func forget(_ tabID: UUID) -> SessionProcess? { processes.removeValue(forKey: tabID) }

    /// Re-establishes (or refreshes) a single tab's record without disturbing any other.
    /// Used by `SessionStore.sweepOrphans` to put a survivor it could not kill back where
    /// `persist()` can see it — the on-disk record is otherwise one-shot, since nothing but
    /// the sweep itself ever repopulates this registry from a previous run's snapshot, and a
    /// survivor the sweep failed to kill would vanish the moment anything else in the new run
    /// persisted.
    func keep(_ tabID: UUID, as process: SessionProcess) { processes[tabID] = process }

    func restore(_ restored: [UUID: SessionProcess]) { processes = restored }
}
