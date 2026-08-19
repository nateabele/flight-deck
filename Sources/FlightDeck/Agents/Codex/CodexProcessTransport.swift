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
    /// is the last whitespace-separated token, and it starts with a digit. Verified against
    /// the real binary at codex-cli 0.142.4, not derived from documentation; if a future
    /// release appends a build hash or channel tag as its own token, this parses closed into
    /// `.notInstalled` rather than a wrong-but-plausible version — re-verify against that
    /// release's actual `--version` output before assuming this still holds.
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
        // `--version` output is far too small to ever fill a pipe buffer, so an unread
        // stderr `Pipe()` here isn't a live deadlock risk — but it's the shape of the classic
        // Foundation.Process deadlock (child blocks writing to a full, undrained pipe), and
        // `CodexProcessTransport.start()` already does the right thing for the real
        // transport's stderr. Match it rather than leave a foot-gun for the next caller who
        // copies this and points it at something chattier.
        process.standardError = FileHandle.nullDevice
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

    /// Fires at most once, however this transport's process stops running: an explicit
    /// `stop()`, `codex app-server` crashing (`terminationHandler`), or exiting cleanly (EOF
    /// — an empty chunk from `readabilityHandler`, which can arrive before, after, or instead
    /// of `terminationHandler`). Wiring this to `rpc.transportClosed()` is the next task's
    /// job — without it, `CodexRPC.request`'s "nothing here can hang a caller forever on a
    /// dead app-server" guarantee breaks the moment the app-server actually dies mid-session,
    /// because nothing else would ever call `transportClosed()`.
    var onTerminate: (() -> Void)?

    private let executable: String
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var reassembler = LineReassembler()
    private var hasTerminated = false

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

        // An empty chunk from `availableData` IS end-of-file, not "nothing happened yet" — it
        // means the pipe's write end closed, which means the process is gone. Routing it to
        // `terminate()` rather than silently dropping it is what lets a crash be noticed at
        // all; without this there is no mechanism, not even a callback, by which anything
        // downstream could learn the app-server exited.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                Task { @MainActor in self?.terminate() }
                return
            }
            Task { @MainActor in self?.consume(chunk) }
        }

        // Belt-and-suspenders alongside the EOF check above: EOF and `terminationHandler` can
        // arrive in either order, so both funnel into the same de-duplicated `terminate()`.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminate() }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw AgentLaunchError.notInstalled(executable)
        }
    }

    func send(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// Idempotent: closing tabs and app quit can both reach this for the same process.
    /// Routes through `terminate()` so an explicit stop leaves the object in exactly the
    /// state a crash would — same handlers torn down, same `onTerminate` firing exactly once.
    func stop() {
        if process.isRunning { process.terminate() }
        terminate()
    }

    /// The single place every way this process can stop running funnels through: explicit
    /// `stop()`, a crash (`terminationHandler`), or a clean exit (EOF). Guarded so
    /// `onTerminate` fires at most once regardless of how many of those actually happen —
    /// `codex app-server` exiting can trigger both EOF and `terminationHandler` for the same
    /// exit, and `stop()` can race either.
    private func terminate() {
        guard !hasTerminated else { return }
        hasTerminated = true
        stdout.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        onTerminate?()
    }

    private func consume(_ chunk: Data) {
        for line in reassembler.feed(chunk) { onLine?(line) }
    }

    /// Backstop for the last strong reference going away without `stop()` ever being called —
    /// a spawn failure with no explicit teardown, a tab closing mid-flight. Direct access to
    /// `process`/the pipes here is legal: `deinit` has unique, non-concurrent access to
    /// `self` during teardown, so no actor hop is needed despite the class being `@MainActor`
    /// (same reasoning as `CodexRPC.deinit`). Deliberately does NOT call `terminate()` /
    /// `onTerminate`: that callback exists to notify a still-alive owner of an unexpected
    /// exit, and by the time `deinit` runs there is no owner left to notify — its only job is
    /// making sure the real OS subprocess doesn't outlive the Swift object that owns it.
    deinit {
        stdout.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }
}

extension CodexProcessTransport {
    /// Test-only: exercises the exact path `readabilityHandler` takes on an empty chunk
    /// (i.e. EOF) — `terminate()` is private and EOF can otherwise only be produced by a real
    /// pipe closing, which the committed suite must not spawn a process to do.
    func simulateEOFForTesting() { terminate() }

    /// Test-only: exercises the exact path `process.terminationHandler` takes, without
    /// spawning a real process to trigger it.
    func simulateProcessTerminationForTesting() { terminate() }
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
    ///
    /// `clientInfo` MUST be present. This used to be `rpc.request("initialize", [:])`, which
    /// reads as "no params to send" but is not what real codex sees: `CodexRPC.request` omits
    /// the whole `"params"` key when its argument is empty (see `CodexRPC.swift`), so the
    /// wire message carried no `params` at all. `codex app-server`'s `InitializeParams`
    /// requires `clientInfo`, and rejected that outright — `-32600 missing field 'params'` —
    /// on every real handshake, against both codex-cli 0.142.4 and 0.147.0. Caught only by
    /// `CodexIntegrationTests`, because every hermetic test talks to a stub transport that
    /// never validates params. See this task's report for the incident.
    static func verifyHandshake(_ rpc: CodexRPC, timeoutSeconds: Double = 5) async throws {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let params: [String: Any] = ["clientInfo": ["name": "flight-deck", "version": version]]
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await rpc.request("initialize", params) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CodexRPCError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
