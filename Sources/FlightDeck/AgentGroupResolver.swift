import Darwin
import Foundation

protocol AgentGroupResolving {
    /// The process group of the agent under `daemonPID` (the daemon's sole direct
    /// child), or nil if the daemon currently has no live child. Always > 0 when non-nil.
    func agentProcessGroup(daemonPID: pid_t) -> pid_t?
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
}
