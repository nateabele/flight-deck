import Foundation

/// fork/exec helper for pgid/signal tests: spawns a command in its OWN process group
/// (POSIX_SPAWN_SETPGROUP + pgroup 0), so the parent can assert group-targeted behavior.
struct ForkedChild {
    let pid: pid_t
    /// With POSIX_SPAWN_SETPGROUP + pgroup 0, the child leads its own group == its pid.
    var expectedPGID: pid_t { pid }

    static func spawnOwnGroup(command: String, args: [String]) throws -> ForkedChild {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0) // 0 => new group led by the child
        var pid: pid_t = 0
        let argv = ([command] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, command, nil, &attr, argv, environ)
        guard rc == 0 else { throw NSError(domain: "spawn", code: Int(rc)) }
        return ForkedChild(pid: pid)
    }

    /// Kills the whole GROUP (leader + any children it forked) so no orphan is left.
    func terminate() { kill(-pid, SIGKILL); var s: Int32 = 0; waitpid(pid, &s, 0) }
    func waitUntilExit() { var s: Int32 = 0; waitpid(pid, &s, 0) }
}
