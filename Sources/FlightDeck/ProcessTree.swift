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
    /// `getpgid` returned a non-positive result). A caller about to signal a group should ask
    /// for this rather than trust a previously recorded value — see `SessionStore.sweepOrphans`
    /// for why that distinction is load-bearing.
    func pgid(of pid: pid_t) -> pid_t?
}

/// The real implementation, over libproc.
struct ProcessTree: ProcessInspecting {
    /// Depth limit for the descendant walk. Terminal process trees are shallow; this only
    /// exists so a pathological or cyclic reading of the table cannot spin forever.
    private static let maxDepth = 16

    func children(of ppid: pid_t) -> Set<pid_t> {
        // The sizing call (buffer=nil) is documented as returning a byte count, but
        // empirically (verified against real macOS 26.5.1) it instead tracks something
        // close to the *system-wide* process total, not a per-ppid estimate, and the real
        // fill call's return value does not reliably line up with a byte offset into the
        // buffer either. Rather than trust either number's units, we zero-initialize a
        // generously oversized buffer and scan every slot ourselves: the kernel only ever
        // writes valid (always-positive) pids into the prefix it fills, so untouched
        // trailing slots stay zero and are filtered out below regardless of what the
        // return value actually meant.
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

    /// Microseconds since the epoch. `pbi_start_tvsec` alone is whole seconds, coarse enough
    /// that two unrelated processes starting within the same second are indistinguishable to
    /// `isAlive` — the single gate between this feature and a signal sent to the wrong
    /// process. `pbi_start_tvusec` is read alongside it and folded in for that reason.
    func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        // A short read means the process died between the call and the copy.
        guard read == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
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
