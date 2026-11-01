import Darwin
import Foundation

protocol AgentGroupResolving {
    /// The process group of the agent under `daemonPID` (the daemon's sole direct
    /// child), or nil if the daemon currently has no live child. Always > 0 when non-nil.
    func agentProcessGroup(daemonPID: pid_t) -> pid_t?
    /// The same question answered from `inspector` (a `ProcessSnapshot` in a probe round), so a
    /// round over many tabs does not repeat the child list and group reads per tab. The default
    /// ignores the inspector, which is right for a resolver that has its own source.
    func agentProcessGroup(daemonPID: pid_t, inspector: ProcessInspecting) -> pid_t?
}

extension AgentGroupResolving {
    func agentProcessGroup(daemonPID: pid_t, inspector: ProcessInspecting) -> pid_t? {
        agentProcessGroup(daemonPID: daemonPID)
    }
}

struct PosixAgentGroupResolver: AgentGroupResolving {
    func agentProcessGroup(daemonPID: pid_t) -> pid_t? {
        guard daemonPID > 0 else { return nil }
        // Direct children only: the daemon forkpty's exactly one child (the agent),
        // which setsid's into its own session/group (pgid == pid). node/MCP grandchildren
        // inherit that group, so the direct child's pgid IS the agent group.
        let count = proc_listchildpids(daemonPID, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let filled = proc_listchildpids(daemonPID, &pids, count * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        for raw in pids.prefix(Int(filled)) where raw > 0 {
            guard kill(raw, 0) == 0 else { continue }   // still alive?
            let pgid = getpgid(raw)
            if pgid > 0 { return pgid }
        }
        return nil
    }

    /// `agentProcessGroup(daemonPID:)` over `inspector`: the daemon's first child it still places
    /// in a process group. A child the inspector does not list is gone, which is what the
    /// `kill(raw, 0)` above asks.
    func agentProcessGroup(daemonPID: pid_t, inspector: ProcessInspecting) -> pid_t? {
        guard daemonPID > 0 else { return nil }
        for child in inspector.children(of: daemonPID).sorted() {
            if let pgid = inspector.pgid(of: child) { return pgid }
        }
        return nil
    }
}
