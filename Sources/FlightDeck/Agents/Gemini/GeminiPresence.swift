import Darwin
import Foundation

/// Which agy conversation a tab's own process tree is running, read from the presence lock agy
/// holds open.
///
/// **Why this is the identity channel.** agy takes no conversation id up front: there is no flag
/// to name one, and `--conversation=<unknown>` silently mints a fresh id (agy-tui-facts §0). So
/// a tab's conversation can only be learned after it exists. agy creates
/// `presence/<id>.lock` when the conversation is created (on the first submit, or on `/clear`)
/// and keeps it OPEN for as long as it runs that conversation — `lsof` showed the fd on the live
/// pid, and `/clear` swapped it for the new conversation's lock within the same process
/// (2026-10-08). So "the presence lock open in a process descended from THIS tab" names this
/// tab's conversation, and nobody else's.
///
/// **Concurrent launches cannot cross.** Two tabs started in the same second each have their
/// own agy pid under their own shell (or fd-abduco daemon); each pid holds only its own lock. A
/// newest-lock-in-the-directory rule would hand both tabs whichever lock appeared last — that is
/// the race this design exists not to have.
///
/// Read-only: it lists file descriptors with libproc and never opens or locks the lock file. An
/// `flock` probe would briefly hold a lock agy itself may be trying to take.
protocol GeminiPresenceReading: Sendable {
    /// The conversation whose presence lock a process descended from any of `roots` holds open,
    /// or nil when no agy is running in that tree (or it has not created a conversation yet).
    func heldConversation(underRoots roots: [pid_t], paths: GeminiPaths) -> UUID?
}

struct GeminiPresence: GeminiPresenceReading {
    var inspector: ProcessInspecting = ProcessTree()

    func heldConversation(underRoots roots: [pid_t], paths: GeminiPaths) -> UUID? {
        var seen: Set<pid_t> = []
        for root in roots where root > 0 {
            for pid in [root] + inspector.descendants(of: root).map(\.pid) where seen.insert(pid).inserted {
                for path in Self.openVnodePaths(of: pid) {
                    if let id = paths.conversation(ofPresenceLockPath: path) { return id }
                }
            }
        }
        return nil
    }

    /// Every regular-file path `pid` holds open, via `PROC_PIDLISTFDS` +
    /// `PROC_PIDFDVNODEPATHINFO` — what `lsof -p` reads. Empty for a process this user cannot
    /// inspect or that exited mid-walk.
    static func openVnodePaths(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                     Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}
