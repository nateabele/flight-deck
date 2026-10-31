// Sources/FlightDeck/ProcessSnapshot.swift
import Darwin
import Foundation

/// The whole process table, read once, answering `ProcessInspecting` from memory.
///
/// **Why it exists.** The two periodic probes — the tab-lease sweep (every 5 s,
/// `SessionStore.reconcileTabLeasesIfDue`) and the smart-sleep round (`SessionSleepController`) —
/// asked `ProcessTree` for every tab's subtree. Each descendant cost a `proc_listchildpids`
/// (its children) plus a `KERN_PROC_PID` sysctl (its start time), so a pass was
/// O(tabs × subtree size) syscalls: a live `sample` of `dev.flightdeck.process-probe` over 10 s
/// put it at ~2.7% of a core (`__proc_info` 124 ms, `__sysctl` 100 ms). One
/// `KERN_PROC_ALL` read returns every process's pid, parent, group, start time and `p_comm`
/// in a single syscall, and every tab's walk becomes dictionary lookups.
///
/// **Only for questions whose wrong answer is cheap.** A snapshot is as old as its read: a
/// process that exited since still answers `isAlive`, and one forked since does not exist. That
/// is fine for "does this tab still run an agent" (re-asked in 5 s) and unacceptable ahead of a
/// signal, so the reaper, `SessionStore`'s quit/orphan sweeps and `PromptService` keep reading
/// `ProcessTree` live. `ProcessTree.snapshot()` is the one way in, and the two probe paths its
/// only callers.
///
/// **Same answers as `ProcessTree`.** `startTime` is `p_starttime` folded to microseconds exactly
/// as `ProcessTree.startTime` does (and nil on the same `tv_sec > 0` rule), so an identity built
/// from either compares equal to the other. `KERN_PROC_ALL`, like `KERN_PROC_PID`, has no libproc
/// EPERM restriction, so the setuid-root `login` children of every session are in it with their
/// parent and group populated (`ProcessSnapshotTests` checks this against this app's own
/// children). `descendants` keeps `ProcessTree`'s depth limit, its depth-first order and its
/// `seen` identity rule; siblings are visited in ascending pid order, where `ProcessTree` walks a
/// `Set` in no particular one.
struct ProcessSnapshot: ProcessInspecting {
    struct Entry: Equatable, Sendable {
        var ppid: pid_t
        /// Microseconds since the epoch; nil on the rule `ProcessTree.startTime` uses.
        var startTime: UInt64?
        var pgid: pid_t
        /// The kernel's `p_comm`: the basename of the EXECUTED file, truncated to 16 bytes.
        /// Changes on exec, which is why `ArgvZeroCache` keys on it. Never an agent's name —
        /// claude's is its version string.
        var comm: String
    }

    /// Mirrors `ProcessTree.maxDepth`.
    private static let maxDepth = 16

    private let entries: [pid_t: Entry]
    private let childrenByParent: [pid_t: [pid_t]]

    init(entries: [pid_t: Entry]) {
        self.entries = entries
        var byParent: [pid_t: [pid_t]] = [:]
        // A pid is never its own child: pid 0 (kernel_task) reports ppid 0.
        for (pid, entry) in entries where entry.ppid != pid { byParent[entry.ppid, default: []].append(pid) }
        self.childrenByParent = byParent.mapValues { $0.sorted() }
    }

    /// Reads the table, or nil when the sysctl fails for good (callers fall back to live reads).
    ///
    /// The sizing call and the fill call race process creation, so the buffer gets headroom and
    /// an `ENOMEM` (the table outgrew even that) retries with a fresh size, a bounded number of
    /// times.
    static func capture() -> ProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            size += size / 8 + 16 * stride
            let capacity = size / stride
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            let status = table.withUnsafeMutableBytes { raw -> Int32 in
                size = raw.count
                return sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return ProcessSnapshot(entries: Dictionary(
                table.prefix(size / stride).map { info in
                    (info.kp_proc.p_pid, Entry(
                        ppid: info.kp_eproc.e_ppid, startTime: startTime(of: info),
                        pgid: info.kp_eproc.e_pgid, comm: comm(of: info)))
                },
                uniquingKeysWith: { first, _ in first }))
        }
        return nil
    }

    private static func startTime(of info: kinfo_proc) -> UInt64? {
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    private static func comm(of info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `p_comm` of `pid`, nil when it is not in the snapshot.
    func comm(of pid: pid_t) -> String? { entries[pid]?.comm }

    func children(of ppid: pid_t) -> Set<pid_t> { Set(childrenByParent[ppid] ?? []) }

    func descendants(of pid: pid_t) -> [ProcessIdentity] {
        var found: [ProcessIdentity] = []
        var seen: Set<pid_t> = [pid]
        var frontier = [(pid: pid, depth: 0)]

        while let (current, depth) = frontier.popLast() {
            guard depth < Self.maxDepth else { continue }
            for child in childrenByParent[current] ?? [] where !seen.contains(child) {
                seen.insert(child)
                if let start = entries[child]?.startTime { found.append(ProcessIdentity(pid: child, procStart: start)) }
                frontier.append((child, depth + 1))
            }
        }
        return found
    }

    func startTime(of pid: pid_t) -> UInt64? { entries[pid]?.startTime }

    func isAlive(_ identity: ProcessIdentity) -> Bool { startTime(of: identity.pid) == identity.procStart }

    func pgid(of pid: pid_t) -> pid_t? {
        guard let group = entries[pid]?.pgid, group > 0 else { return nil }
        return group
    }

    /// A snapshot is already a snapshot.
    func snapshot() -> ProcessInspecting { self }
}

/// argv[0] by process, remembered across probe passes.
///
/// `KERN_PROCARGS2` is two sysctls per process (size, then fill) and a walk reads it for every
/// descendant of every tab on every pass, though a process's argv[0] changes only when it
/// execs. The key is `(pid, start time, p_comm)`: the start time retires a recycled pid, and
/// `p_comm` changes on exec — a shell that `exec`s the agent keeps both its pid and its start
/// time, and is the one case the start time alone would get wrong. `p_comm` cannot replace the
/// read, though: claude's is its version string, so the name check stays on argv[0].
///
/// An unreadable answer (nil) is remembered too. The setuid-root `login` that parents every
/// session is unreadable for good, and re-asking it every pass is most of the cost this removes.
///
/// Bounded by `prune`, which drops every entry whose process is no longer in the inspector.
final class ArgvZeroCache: @unchecked Sendable {
    private struct Key: Hashable {
        var pid: pid_t
        var start: UInt64
        var comm: String
    }

    private let lock = NSLock()
    private var values: [Key: String?] = [:]

    var count: Int { lock.withLock { values.count } }

    /// `pid`'s argv[0]: remembered, or `read` once and then remembered. A process the inspector
    /// cannot place (no start time) is read through, uncached — there is nothing to key on.
    func argv0(of pid: pid_t, in inspector: ProcessInspecting, read: (pid_t) -> String?) -> String? {
        guard let start = inspector.startTime(of: pid) else { return read(pid) }
        let key = Key(pid: pid, start: start, comm: inspector.comm(of: pid) ?? "")
        if let known = lock.withLock({ values[key] }) { return known }
        let value = read(pid)
        lock.withLock { values[key] = .some(value) }
        return value
    }

    /// Forgets the processes `inspector` no longer lists (or lists with another start time).
    func prune(keeping inspector: ProcessInspecting) {
        lock.withLock {
            values = values.filter { inspector.isAlive(ProcessIdentity(pid: $0.key.pid, procStart: $0.key.start)) }
        }
    }
}
