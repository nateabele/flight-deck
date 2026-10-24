import Foundation
import IntakeKit

enum CodexDaemonEndpoint {
    /// Starting is idempotent and never stops/restarts a daemon the terminal already uses.
    /// Its private control socket and process outlive Flight Deck's observer connection.
    static func start(executable: String, environment: [String: String], home: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server", "daemon", "start"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0,
              let info = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let path = info["socketPath"] as? String,
              let version = info["appServerVersion"] as? String,
              CodexVersionProbe.isAtLeast(version, minimum: "0.163.0") else {
            throw AgentLaunchError.prepareFailed("Codex's shared daemon did not provide a compatible control socket. Update Codex and retry.")
        }
        return try validatedSocketPath(path, home: home)
    }

    static func validatedSocketPath(_ path: String, home: URL) throws -> String {
        let root = home.resolvingSymlinksInPath().standardizedFileURL.path
        let socket = URL(fileURLWithPath: path).standardizedFileURL
        let parent = socket.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        // Codex places a symlink in the account's control directory pointing at a shorter
        // private /tmp socket (Unix socket paths have a length limit). Validate the containing
        // account directory before following that final symlink, then use its short target.
        guard parent == root || parent.hasPrefix(root + "/") else {
            throw AgentLaunchError.prepareFailed("Codex returned a control socket outside this account's home.")
        }
        return socket.resolvingSymlinksInPath().path
    }
}
