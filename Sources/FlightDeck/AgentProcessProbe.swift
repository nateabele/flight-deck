import Darwin
import Foundation
import IntakeKit

/// Whether a tab's AGENT is running — not its shell. What a tab's pool lease follows (a lease
/// is held while the agent process lives, `SessionStore.reconcileTabLeases`).
///
/// **Why the process table and not `statuses`.** Only claude has a liveness signal (its
/// pid-keyed status registry); codex, grok and gemini tabs keep whatever their runtime last
/// reported, for the life of the app, because none of them announces its own death. A probe
/// that read `statuses` would hold every codex lease forever. The process table answers for
/// every agent the same way.
///
/// **Why argv[0] and not the process name.** The kernel's `p_comm` is the basename of the
/// EXECUTED file, and two of the four agents run a versioned file through a symlink: a live
/// claude reads `2.1.293` and grok `grok-macos-aarch` (`ps -o ucomm`, 2026-10-09). argv[0] is
/// what the shell was asked to run — `claude`, `grok`, `codex`, `agy` — which is each profile's
/// `binaryName`.
///
/// A SIGSTOP'd agent (smart sleep) is still in the table, so it still counts as running.
struct AgentProcessProbe {
    var inspector: ProcessInspecting = ProcessTree()
    var argv0: (pid_t) -> String? = ProcessArguments.argv0(of:)

    /// True when a process descended from any of `roots` (the tab's fd-abduco daemon, its
    /// surface's shell) was started as `agent`'s binary.
    func isRunning(_ agent: AgentID, under roots: [pid_t]) -> Bool {
        let name = AgentProfiles.profile(for: agent).binaryName
        var seen: Set<pid_t> = []
        for root in roots where root > 0 {
            for process in inspector.descendants(of: root) where seen.insert(process.pid).inserted {
                if let first = argv0(process.pid), (first as NSString).lastPathComponent == name { return true }
            }
        }
        return false
    }
}

enum ProcessArguments {
    /// `pid`'s argv[0], from `KERN_PROCARGS2` (what `ps -o args` reads), or nil when the
    /// process is gone or not readable by this user.
    ///
    /// Layout: an `Int32` argc, the executable path, NUL padding, then argv. The first
    /// non-empty string after the path is argv[0].
    static func argv0(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(size)
        var index = MemoryLayout<Int32>.size
        // Skip the executable path, then the NULs that pad it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        let start = index
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}
