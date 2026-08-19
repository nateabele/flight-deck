import Foundation

@MainActor
protocol ToolLaunching {
    func launch(command: String, in directory: String, named: String)
}

/// Runs an expanded tool command through the user's login shell, detached.
///
/// **Why the login shell.** Flight Deck launched from Finder has a minimal environment: no
/// `$EDITOR`, and a `PATH` without `/opt/homebrew/bin`. `$SHELL -lc` sources the profile, so a
/// template behaves exactly as it would typed into a terminal — which also means shell syntax
/// in a template (pipes, `&&`, quoting) works as written.
@MainActor
struct ShellToolLauncher: ToolLaunching {
    /// Honours the Shell & Environment pane's override, like session creation does.
    var shell: () -> String = { ShellResolver.resolve() }
    var environment: () -> [String: String] = { ProcessInfo.processInfo.environment }
    var reporter: ToolLaunchFailureReporting = NSAlertToolLaunchFailureReporter()
    /// How long a child has to fail before it is assumed to have started fine. Long enough for
    /// a bad command to die, short enough that a real failure is reported while the user still
    /// remembers pressing the key.
    var grace: Duration = .seconds(2)

    func launch(command: String, in directory: String, named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell())
        process.arguments = ["-lc", command]
        // Relative paths in a template resolve where the user expects, and a tool that reads
        // its cwd rather than argv still lands in the right place.
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment()

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

        Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: grace)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard !process.isRunning else {
                // A GUI editor stays alive, and that is success. Stop holding the read end
                // first: a chatty long-running child would otherwise fill the pipe's buffer
                // and block forever on its next write to stderr.
                errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
                return
            }

            guard process.terminationStatus != 0 else { return }

            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text.split(separator: "\n").last.map(String.init)
                ?? "exited with status \(process.terminationStatus)"
            reporter.report(tool: name, message: message)
        }
    }
}
