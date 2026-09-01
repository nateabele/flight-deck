import Foundation

/// The `PATH` a login shell produces, for the agent binaries Flight Deck spawns itself.
///
/// **Why this exists.** Flight Deck launched from Finder or the Dock inherits launchd's bare
/// environment — measured against a running app, not assumed:
///
///     ps eww <pid> -> PATH=/usr/bin:/bin:/usr/sbin:/sbin
///
/// Both `codex` and `claude` live in `~/.local/bin` on this machine, and homebrew installs land
/// in `/opt/homebrew/bin`. Neither directory is in that PATH, so `/usr/bin/env codex --version`
/// cannot find a codex that is installed and on the user's own `$PATH`, and
/// `CodexVersionProbe.check` reports `.notInstalled` — an error that names the right symptom
/// and the wrong cause.
///
/// **Why only codex noticed.** Claude is launched by typing into a ghostty pty running the
/// user's login shell, which sources their profile and gets the full PATH. Codex is the only
/// agent the app spawns as a child process of itself, so it is the only one that sees launchd's
/// PATH. The asymmetry is the bug, not codex.
///
/// `ShellToolLauncher` already solves this for tool templates by running them through
/// `$SHELL -lc`; this is the same move reduced to the single variable these two spawn sites
/// need, so neither has to become a shell invocation with the quoting that implies.
enum LoginShellPath {
    /// Resolved once per run. The lookup spawns a login shell, which sources the user's whole
    /// profile — cheap once, wasteful on every version probe and every app-server start.
    /// `nil` means the lookup failed and callers should leave the inherited PATH alone rather
    /// than replace it with something worse.
    private static let cached: String? = lookUp()

    static func resolve() -> String? { cached }

    /// How long the login shell gets before we give up and keep the inherited PATH. A profile
    /// that hangs must not hang session creation; the same reasoning as `CodexVersionProbe`'s
    /// own watchdog, and the same budget.
    static let timeoutSeconds: Double = 5

    /// `printenv PATH`, **not** `echo $PATH`. In fish — the shell in use on this machine — a
    /// `$PATH` is a list and `echo` joins it with SPACES, which yields a string no `execvp`
    /// can use and would silently produce a PATH with exactly one bogus entry. `printenv`
    /// prints the exported, colon-separated value, and does so identically in fish, zsh and
    /// bash.
    ///
    /// `-lc` rather than `-c`: the profile that sets PATH is a *login* profile, which is
    /// precisely what a Finder launch skipped.
    static func lookUp(
        shell: String = ShellResolver.resolve(),
        run: (String, [String]) throws -> String = defaultRun
    ) -> String? {
        guard let output = try? run(shell, ["-lc", "printenv PATH"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A shell that answered with nothing usable leaves the caller on the inherited PATH.
        // One bare directory is not a PATH worth trusting either — it is what a fish `echo`
        // bug would look like if the command above were ever "simplified" back to `echo`.
        guard !path.isEmpty, path.contains("/") else { return nil }
        return path
    }

    private static func defaultRun(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Matches `CodexVersionProbe.defaultRun`: an undrained stderr pipe is the classic
        // Foundation.Process deadlock shape even when this particular output is small.
        process.standardError = FileHandle.nullDevice
        try process.run()

        // A profile that never returns must not wedge the app. SIGTERM closes the child's end
        // of the pipe, which is what lets the read below return; the caller then sees empty
        // output and keeps the inherited PATH.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

        // Read before waiting — see `CodexVersionProbe.defaultRun` for why this ordering is
        // not interchangeable.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `base` with the login shell's PATH substituted in, or `base` unchanged when the lookup
    /// failed. Callers hand this to `Process.environment` so `/usr/bin/env` resolves the agent
    /// the way the user's own terminal would.
    static func repairing(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        path: String? = resolve()
    ) -> [String: String] {
        guard let path else { return base }
        var environment = base
        environment["PATH"] = path
        return environment
    }
}
