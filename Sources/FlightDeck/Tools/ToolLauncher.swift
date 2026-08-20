import Foundation

@MainActor
protocol ToolLaunching {
    /// `environmentOverrides` wins on collision with everything else the launcher would set —
    /// see `ToolRunner.run` for why it is passed in here rather than folded into
    /// `ShellToolLauncher`'s own `environment` closure.
    func launch(command: String, in directory: String, named: String, environmentOverrides: [String: String])
}

extension ToolLaunching {
    /// Convenience for the few call sites (previews, direct-launcher tests) with no session,
    /// and so no account, to overlay.
    func launch(command: String, in directory: String, named name: String) {
        launch(command: command, in: directory, named: name, environmentOverrides: [:])
    }
}

/// Bounded tail of a child's stderr, filled by a background reader that never stops draining.
///
/// A `Pipe` has a 64 KiB kernel buffer. If nothing reads it, a child that writes more than
/// that blocks inside `write()` — and a process blocked in a syscall still reports
/// `isRunning == true`, so a launch failure that happens to be verbose would look identical to
/// a launch that succeeded. Draining continuously from the moment the child starts is what
/// keeps that from ever happening; only the tail is kept, because the report only ever needs
/// the last line.
private final class StderrTail {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let cap = 8192

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        // Trimmed from the front, so the earliest bytes may be cut mid-character — harmless,
        // since only the last line is ever reported.
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var lastLine: String? {
        lock.lock()
        let data = buffer
        lock.unlock()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").last.map(String.init)
    }
}

/// Runs an expanded tool command through the user's login shell, detached.
///
/// **Why the login shell.** Flight Deck launched from Finder has a minimal environment: no
/// `$EDITOR`, and a `PATH` without `/opt/homebrew/bin`. `$SHELL -lc` sources the profile, so a
/// template behaves exactly as it would typed into a terminal — which also means shell syntax
/// in a template (pipes, `&&`, quoting) works as written.
@MainActor
struct ShellToolLauncher: ToolLaunching {
    /// Overridden by `configured(_:)` to read `PreferencesStore.resolvedShell()`. The bare
    /// default here only fires for a launcher nobody wired to preferences (tests), so it falls
    /// back to `$SHELL` directly rather than silently dropping the user's override.
    var shell: () -> String = { ShellResolver.resolve() }
    /// Overridden by `configured(_:)` to merge in `ShellPreferences.environment`. The bare
    /// default is the plain process environment, same caveat as `shell` above.
    var environment: () -> [String: String] = { ProcessInfo.processInfo.environment }
    var reporter: ToolLaunchFailureReporting = NSAlertToolLaunchFailureReporter()
    /// How long a child has to fail before it is assumed to have started fine. Long enough for
    /// a bad command to die, short enough that a real failure is reported while the user still
    /// remembers pressing the key.
    var grace: Duration = .seconds(2)

    func launch(
        command: String, in directory: String, named name: String,
        environmentOverrides: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell())
        process.arguments = ["-lc", command]
        // Relative paths in a template resolve where the user expects, and a tool that reads
        // its cwd rather than argv still lands in the right place.
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        // Overrides win last: they are the session's own account, which must never be shadowed
        // by a Shell & Environment pane value typed for a different login.
        var environment = environment()
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment

        let errors = Pipe()
        process.standardError = errors
        // Null rather than inherited: a detached tool must not hold Flight Deck's descriptors,
        // and nothing reads its stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            reporter.report(tool: name, message: error.localizedDescription)
            return
        }

        // Draining starts immediately, not lazily at the grace deadline: a child that fills
        // the pipe before then would otherwise block in `write()` and read as still-running,
        // turning a failed — but verbose — launch into a reported success. `availableData`
        // blocks until there is something to read and returns empty at EOF, so this reader
        // needs no cancellation of its own: it exits by itself once the child's stderr closes.
        let tail = StderrTail()
        DispatchQueue.global(qos: .utility).async {
            let handle = errors.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
            }
            try? handle.close()
            tail.finish()
        }

        Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: grace)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }

            // Still alive past the grace window is success: a GUI editor stays running, and
            // the reader above keeps draining its stderr for as long as it runs.
            guard !process.isRunning else { return }

            guard process.terminationStatus != 0 else { return }

            // The reader may not have appended the child's last chunk yet — wait for it to
            // reach EOF, bounded, so a wedged reader can never hang the report.
            let readerDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            while !tail.isFinished, ContinuousClock.now < readerDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }

            let message = tail.lastLine ?? "exited with status \(process.terminationStatus)"
            reporter.report(tool: name, message: message)
        }
    }
}

extension ShellToolLauncher {
    /// The one launcher every production call site should use, so the Shell & Environment
    /// pane's override actually reaches tool launches — the bug this exists to close was two
    /// call sites each constructing a bare `ShellToolLauncher()` and wiring neither `shell` nor
    /// `environment` to preferences at all.
    ///
    /// `preferences` is captured weakly and read inside the closures rather than snapshotted
    /// here, so an edit made in the pane after this launcher is built still applies to the next
    /// launch instead of being frozen at construction time.
    ///
    /// Deliberately not `PreferencesStore.sessionEnvironment(inherited:)`: that also blanks
    /// `CLAUDE_CODE_CHILD_SESSION`, which exists to keep a nested Claude session's transcript
    /// writing (and the sidebar's rename sync that depends on it) alive — a session-creation
    /// concern with nothing to say about launching an editor or a terminal. The pane's raw
    /// `shell.environment` is merged in directly instead.
    @MainActor
    static func configured(_ preferences: PreferencesStore) -> ShellToolLauncher {
        var launcher = ShellToolLauncher()
        launcher.shell = { [weak preferences] in
            preferences?.resolvedShell() ?? ShellResolver.resolve()
        }
        launcher.environment = { [weak preferences] in
            var environment = ProcessInfo.processInfo.environment
            // The pane's values win on collision — a user who sets a variable there means to
            // override whatever Flight Deck inherited from Finder or the login shell.
            if let overrides = preferences?.preferences.shell.environment {
                environment.merge(overrides) { _, override in override }
            }
            return environment
        }
        return launcher
    }
}
