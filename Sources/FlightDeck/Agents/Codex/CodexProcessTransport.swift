import Foundation

/// Why a codex launch failed to produce a usable tab. Named causes rather than one generic
/// string wherever the fix differs — "install/upgrade codex" reads differently from "codex
/// refused this specific thread."
enum AgentLaunchError: LocalizedError, Equatable {
    case notInstalled(String)
    case versionTooOld(found: String, minimum: String)
    case prepareFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "\(name) is not installed or not on PATH."
        case .versionTooOld(let found, let minimum):
            "Codex \(found) is too old; the app-server protocol Flight Deck uses needs \(minimum) or newer."
        case .prepareFailed(let why):
            "Could not start a Codex session: \(why)"
        }
    }
}

/// Reassembles newline-delimited UTF-8 text across chunk boundaries. Split out from
/// `CodexProcessTransport` so the splitting logic is testable without a real pipe — a
/// `readabilityHandler` callback can hand back a partial line, and half a JSON object
/// parses as nothing.
struct LineReassembler {
    private var buffer = Data()

    /// Feeds one chunk of raw bytes; returns every complete line it produced, in order.
    /// Incomplete trailing text is held back for the next call rather than dropped.
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if let text = String(data: Data(line), encoding: .utf8) { lines.append(text) }
        }
        return lines
    }
}

/// Confirms `codex` is on PATH and speaks a protocol Flight Deck understands, before any
/// long-lived process is spawned for real. Parsing and comparison are pure so they're
/// testable without running the binary; `run` is the one seam that actually shells out, and
/// production's default implementation is the only part a committed test may not exercise.
enum CodexVersionProbe {
    /// The app-server protocol used here (newline-delimited JSON, `thread/start`,
    /// `thread/name/set`, …) exists in codex-cli 0.142.4 and newer — verified directly
    /// against the binary, not derived from a changelog.
    static let minimumVersion = "0.142.4"

    /// Runs `codex --version`, parses it, and throws the launch error that names what's
    /// wrong. `executable` also names the binary in that error; `run` is injected so tests
    /// can supply canned output instead of spawning a real process.
    static func check(
        executable: String = "codex",
        run: (String) throws -> String = defaultRun
    ) throws {
        guard let output = try? run(executable), let found = parse(output) else {
            throw AgentLaunchError.notInstalled(executable)
        }
        guard isAtLeast(found, minimum: minimumVersion) else {
            throw AgentLaunchError.versionTooOld(found: found, minimum: minimumVersion)
        }
    }

    /// codex prints e.g. `codex-cli 0.142.4` on the first line of `--version` — the version
    /// is the last whitespace-separated token, and it starts with a digit.
    static func parse(_ output: String) -> String? {
        guard let firstLine = output.split(separator: "\n", maxSplits: 1).first,
              let token = firstLine.split(separator: " ").last.map(String.init),
              token.first?.isNumber == true
        else { return nil }
        return token
    }

    /// Dotted-triple comparison, missing components treated as 0 — good enough for codex's
    /// `MAJOR.MINOR.PATCH` scheme, not a general semver parser (no pre-release/build tags).
    static func isAtLeast(_ version: String, minimum: String) -> Bool {
        let found = version.split(separator: ".").map { Int($0) ?? 0 }
        let floor = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(found.count, floor.count) {
            let a = i < found.count ? found[i] : 0
            let b = i < floor.count ? floor[i] : 0
            if a != b { return a > b }
        }
        return true
    }

    /// Shells out via `/usr/bin/env` so `executable` resolves against `$PATH` the same way a
    /// shell would, whether codex lives in `/opt/homebrew/bin` or an `nvm`/`asdf`-style
    /// install. If `executable` itself can't be found, `env` exits nonzero with nothing on
    /// stdout, which `parse` above already treats as "not installed" — no separate check
    /// needed here.
    private static func defaultRun(_ executable: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Spawns `codex app-server` and pumps newline-delimited JSON both ways.
///
/// Long-lived and app-wide: a codex thread belongs to the app-server process that created
/// it, so restarting per session would discard threads.
@MainActor
final class CodexProcessTransport: CodexTransport {
    var onLine: ((String) -> Void)?

    private let executable: String
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var reassembler = LineReassembler()

    init(executable: String = "codex") { self.executable = executable }

    /// Spawns the process. `/usr/bin/env` resolves `executable` against `$PATH`, same as
    /// `CodexVersionProbe`. The `process.run()` failure this catches is the degenerate case
    /// (`/usr/bin/env` itself missing or unrunnable) — the ordinary "codex not installed"
    /// case is expected to have already been rejected by a prior `CodexVersionProbe.check`,
    /// since `env` succeeds at launching even when the *target* it names does not exist.
    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw AgentLaunchError.notInstalled(executable)
        }
    }

    func send(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// Idempotent: closing tabs and app quit can both reach this for the same process.
    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func consume(_ chunk: Data) {
        for line in reassembler.feed(chunk) { onLine?(line) }
    }
}

extension CodexProcessTransport {
    /// Sends `initialize` over `rpc` and bounds the wait. Without this, a `codex app-server`
    /// that spawned but never speaks — a broken install, a prompt with nothing behind it —
    /// hangs session creation forever: `CodexRPC.request` only resolves on a reply,
    /// `transportClosed()`, or `deinit`, none of which a wedged-but-still-alive process ever
    /// triggers on its own. Racing the request against a timer and cancelling whichever loses
    /// is what `CodexRPCError.timeout` exists for; it only works because `request` is
    /// cancellation-aware, so losing this race actually retires the in-flight call instead of
    /// abandoning it.
    static func verifyHandshake(_ rpc: CodexRPC, timeoutSeconds: Double = 5) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await rpc.request("initialize", [:]) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CodexRPCError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
