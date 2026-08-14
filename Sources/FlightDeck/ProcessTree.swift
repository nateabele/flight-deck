// Sources/FlightDeck/ProcessTree.swift
import Darwin
import Foundation

/// Reads the live process table. Injected as a protocol so the reaper's logic can be tested
/// against a scripted tree instead of real processes.
protocol ProcessInspecting: Sendable {
    func children(of ppid: pid_t) -> Set<pid_t>
    /// Every descendant, depth-first, each carrying its identity at the moment of the walk.
    func descendants(of pid: pid_t) -> [ProcessIdentity]
    func startTime(of pid: pid_t) -> UInt64?
    func isAlive(_ identity: ProcessIdentity) -> Bool
    /// The live process group of `pid`, or `nil` if the read failed (the process is gone, or
    /// `getpgid` returned a non-positive result). A caller about to signal a group must ask for
    /// this rather than trust a previously recorded value — see `SessionStore.reapSession` and
    /// `sweepOrphans` for why that distinction is load-bearing. Nothing records a pgid any more.
    func pgid(of pid: pid_t) -> pid_t?
}

/// The real implementation, over libproc.
struct ProcessTree: ProcessInspecting {
    /// Depth limit for the descendant walk. Terminal process trees are shallow; this only
    /// exists so a pathological or cyclic reading of the table cannot spin forever.
    private static let maxDepth = 16

    func children(of ppid: pid_t) -> Set<pid_t> {
        // The sizing call (buffer=nil) is documented as returning a byte count, but
        // empirically (verified against real macOS 26.5.1) it instead tracks something close
        // to the *system-wide* process total, not a per-ppid estimate. The fill call's return
        // value is a *pid count* — libproc divides the bytes it wrote by `sizeof(int)` before
        // returning — so the two calls do not even report in the same units. Rather than
        // reason about which is which, we zero-initialize a generously oversized buffer and
        // scan every slot: the kernel only writes valid (always-positive) pids into the prefix
        // it fills, so untouched trailing slots stay zero and are filtered out below.
        let sizing = proc_listchildpids(ppid, nil, 0)
        guard sizing > 0 else { return [] }

        // Headroom: the child set can grow between the sizing call and the fill call, and a
        // short buffer silently truncates rather than erroring.
        let capacity = Int(sizing) + 16
        var buffer = [pid_t](repeating: 0, count: capacity)
        let filled = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(ppid, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }

        return Set(buffer.filter { $0 > 0 })
    }

    func descendants(of pid: pid_t) -> [ProcessIdentity] {
        var found: [ProcessIdentity] = []
        var seen: Set<pid_t> = [pid]
        var frontier = [(pid: pid, depth: 0)]

        while let (current, depth) = frontier.popLast() {
            guard depth < Self.maxDepth else { continue }
            for child in children(of: current) where !seen.contains(child) {
                seen.insert(child)
                if let identity = identity(of: child) { found.append(identity) }
                frontier.append((child, depth + 1))
            }
        }
        return found
    }

    /// Microseconds since the epoch, or `nil` when there is no such process.
    ///
    /// **Why `sysctl` and not `proc_pidinfo(PROC_PIDTBSDINFO)`.** libproc refuses to report on a
    /// process the caller does not own: it returns 0 with `EPERM`. That is not a corner case
    /// here — it is *every session*. libghostty's direct child on macOS is
    /// `/usr/bin/login -flp …`, which is setuid root, so `PROC_PIDTBSDINFO` fails for every
    /// shell this app forks (measured: `proc_pidinfo` → `0/136, EPERM` for each of eighteen live
    /// session children, while the app's own pid reads fine). With libproc, `startTime` was nil
    /// for every session, which meant no identity could be built, nothing was ever recorded, and
    /// `isAlive` answered "dead" for every live shell — the reaper's identity gate silently
    /// refusing to signal anything at all.
    ///
    /// `KERN_PROC_PID` has no such restriction: it is what `ps` reads to show start times for
    /// every process on the machine, root-owned ones included. `p_starttime` is the same kernel
    /// value `pbi_start_tvsec`/`pbi_start_tvusec` expose — verified equal to the microsecond on a
    /// pid readable through both — so identities persisted by an earlier build still compare.
    ///
    /// Whole seconds alone would be too coarse: two unrelated processes starting within the same
    /// second would be indistinguishable to `isAlive`, the single gate between this feature and a
    /// signal sent to the wrong process. `tv_usec` is folded in for that reason.
    func startTime(of pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        // A zero-length answer (rather than an error) is how `KERN_PROC_PID` reports "no such
        // process" — the pid died between the caller's decision and this read.
        guard size > 0 else { return nil }

        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    func identity(of pid: pid_t) -> ProcessIdentity? {
        startTime(of: pid).map { ProcessIdentity(pid: pid, procStart: $0) }
    }

    /// Alive *and still the same process*. The start-time comparison is the whole point:
    /// without it this would happily report a recycled pid as our long-dead shell.
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        startTime(of: identity.pid) == identity.procStart
    }

    func pgid(of pid: pid_t) -> pid_t? {
        let result = getpgid(pid)
        return result > 0 ? result : nil
    }
}
