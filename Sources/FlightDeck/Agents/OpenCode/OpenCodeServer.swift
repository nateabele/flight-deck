import CryptoKit
import Darwin
import Foundation
import IntakeKit
import OSLog

/// Where an account's server answers, and the password it checks.
struct OpenCodeEndpoint: Equatable, Sendable {
    let url: URL
    let password: String
}

/// The per-account `opencode serve` process, as the store sees it. A protocol so store-level
/// tests can stand a fake in front of it — the committed suite must never spawn `opencode`.
@MainActor
protocol OpenCodeServing: AnyObject {
    /// Where the server answers once `start()` has succeeded; nil before.
    var endpoint: OpenCodeEndpoint? { get }
    /// The password this account's server checks. Known from construction — before any start —
    /// because a restored tab's shell is built with it in its environment before the server is.
    var password: String { get }
    /// This account's `opencode.db`, once the server has created it.
    var databaseURL: URL? { get }
    func start() async throws
    func stop()
}

/// **One `opencode serve` per account, deliberately OUTLIVING Flight Deck.**
///
/// Every tab of an account runs `opencode attach <url>` against this one server, which owns
/// the account's sessions, its event stream and its pending permission requests. Two facts
/// from live probing shape its lifetime:
///
/// - **Attached TUIs depend on it, and reconnect on their own.** Killing the server left both
///   attached TUIs alive; restarting it on the SAME port brought them back with no input.
/// - **Everything it holds in memory is lost when it dies** — the running turn, the queue of
///   prompts behind it, every pending permission (the TUI kept drawing a dialog the new server
///   had never heard of).
///
/// So the process is not a child Flight Deck tears down on quit: tabs live on in `fd-abduco`
/// across an app restart (see `SessionDaemon`), and a server that died with the app would cut
/// every one of them off mid-turn. It is spawned detached, its pid, port and password are kept
/// in a state file, and the next launch ADOPTS it when it still answers. When it does not, the
/// replacement takes the same port, so any TUI still attached reconnects without being
/// retyped. Flight Deck stops it only when the account's last OpenCode tab closes.
///
/// The password (`OPENCODE_SERVER_PASSWORD`; OpenCode checks it as HTTP basic auth for user
/// `opencode`, live-probed: 401 without, 200 with) is stable per account for the same reason:
/// a surviving shell carries it in its environment, and a new password would lock it out.
@MainActor
final class OpenCodeServer: OpenCodeServing {
    struct State: Codable, Equatable {
        var pid: Int32?
        var port: Int?
        var password: String
    }

    /// The oldest release this adapter's wire claims were probed against.
    static let minimumVersion = "1.18.0"

    let home: URL
    private let stateURL: URL
    private let logURL: URL
    private(set) var endpoint: OpenCodeEndpoint?
    private var state: State
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "opencode"
    )

    var password: String { state.password }

    var databaseURL: URL? { OpenCodeMirror.databaseURL(home: home) }

    /// `home` is the account's XDG data root (`~/.local/share` for the built-in account): the
    /// directory OpenCode puts `opencode/` — sessions database, provider credentials — inside.
    init(home: URL, root: URL = OpenCodeServer.defaultRoot) {
        self.home = home
        let key = Insecure.SHA1.hash(data: Data(home.standardizedFileURL.path.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        stateURL = root.appendingPathComponent("\(key).json")
        logURL = root.appendingPathComponent("\(key).log")
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State(pid: nil, port: nil, password: Self.newPassword())
            save()
        }
    }

    nonisolated static var defaultRoot: URL {
        FileSessionPersistence.defaultDirectory()
            .appendingPathComponent("OpenCode", isDirectory: true)
            .appendingPathComponent("servers", isDirectory: true)
    }

    /// Adopts a server that is already answering, else spawns one. Idempotent, and cheap when
    /// the server is up (one health request) — `OpenCodeRuntime` calls it to revive a server
    /// that died under attached tabs.
    func start() async throws {
        if let endpoint, await Self.isHealthy(endpoint) { return }
        if let port = state.port {
            let candidate = Self.endpoint(port: port, password: state.password)
            // A recorded process that is still alive gets a real grace period rather than one
            // 2 s probe: a survivor busy with a turn, a migration or a loaded machine can miss
            // one, and treating it as dead would start a SECOND server on the same database
            // while the attached TUIs stay on the first — their turns would never reach Flight
            // Deck. If it is alive and still silent after that, it is wedged: kill it, then
            // take its port.
            let alive = state.pid.map { kill($0, 0) == 0 } ?? false
            for attempt in 0..<(alive ? 20 : 1) {
                if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
                if await Self.isHealthy(candidate) {
                    endpoint = candidate
                    return
                }
            }
            if alive, let pid = state.pid {
                kill(pid, SIGKILL)
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let executable = try await Self.locate()
        let port = Self.reusablePort(state.port) ?? Self.freePort()
        guard let port else { throw OpenCodeError.unreachable("no free loopback port") }
        let pid = try spawn(executable: executable, port: port)
        state.pid = pid
        state.port = port
        save()
        let candidate = Self.endpoint(port: port, password: state.password)
        // OpenCode installs and migrates on first start; a cold one took ~2 s on the build
        // machine. Fifteen seconds is generous without letting a wedged spawn hang a tab.
        for _ in 0..<60 {
            if let version = await Self.version(candidate) {
                // Checked against the RUNNING server's own report rather than a separate
                // `opencode --version`, which took 3.7–4.7 s of wall time on 0.6 s of CPU on the
                // build machine — flaky against any sane timeout, and pure latency on every start.
                guard CodexVersionProbe.isAtLeast(version, minimum: Self.minimumVersion) else {
                    stop()
                    throw AgentLaunchError.agentTooOld(agent: "OpenCode", found: version, minimum: Self.minimumVersion)
                }
                endpoint = candidate
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw AgentLaunchError.agentFailed(
            agent: "OpenCode",
            why: "`opencode serve` did not answer on port \(port) within 15 s — see \(logURL.path)."
        )
    }

    /// SIGTERM, then SIGKILL if it is still there five seconds later.
    ///
    /// The escalation is measured, not cautious: in a live run `opencode serve` was still
    /// answering health checks ten seconds after SIGTERM while a client (the runtime's event
    /// stream) held a connection open — it drains connections rather than dropping them. A
    /// server that outlives its last tab holds a port and a model connection for nothing.
    func stop() {
        if let pid = state.pid, pid > 0 {
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                // `kill(pid, 0)` is "does it still exist". The pid is ours and was alive a
                // moment ago; a recycled pid inside five seconds is not a realistic risk.
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        state.pid = nil
        // The port is forgotten too. It is remembered so a server that CRASHED under attached
        // tabs comes back where they are reconnecting to; an intentional stop has no tabs
        // left, and a remembered port would let the next start adopt this server during the
        // seconds it is still draining — and attach a new tab to it just before the SIGKILL.
        state.port = nil
        endpoint = nil
        save()
    }

    // MARK: - Spawning

    private func spawn(executable: String, port: Int) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        var environment = LoginShellPath.repairing()
        environment["XDG_DATA_HOME"] = home.path
        environment["OPENCODE_SERVER_PASSWORD"] = state.password
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", "--port", String(port), "--hostname", "127.0.0.1"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // A file, not a pipe: a pipe's reader is this process, and once Flight Deck quits the
        // server's next log line would be written into a closed pipe and SIGPIPE it — the
        // very death this design exists to avoid.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        return process.processIdentifier
    }

    /// Finds `opencode` on the login shell's PATH, off the main actor — resolving that PATH runs
    /// the user's login shell once (`LoginShellPath`). The installer's own location is tried
    /// last, for a shell profile that never added it.
    static func locate() async throws -> String {
        try await Task.detached {
            let path = LoginShellPath.repairing()["PATH"] ?? ""
            let candidates = path.split(separator: ":").map { "\($0)/opencode" }
                + ["\(NSHomeDirectory())/.opencode/bin/opencode"]
            guard let executable = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else { throw AgentLaunchError.notInstalled("opencode") }
            return executable
        }.value
    }

    // MARK: - Ports, health, state

    static func endpoint(port: Int, password: String) -> OpenCodeEndpoint {
        OpenCodeEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!, password: password)
    }

    static func isHealthy(_ endpoint: OpenCodeEndpoint) async -> Bool {
        await version(endpoint) != nil
    }

    /// The server's own version, or nil when it does not answer (or refuses the password).
    static func version(_ endpoint: OpenCodeEndpoint) async -> String? {
        let http = URLSessionOpenCodeHTTP(baseURL: endpoint.url, password: endpoint.password, timeout: 2)
        guard let reported = try? await OpenCodeClient(http: http).health() else { return nil }
        // A healthy server that does not say its version is accepted, not refused as "0": the
        // field is informational in OpenCode's schema, and refusing a working server over a
        // missing label would be the worse failure.
        return reported ?? minimumVersion
    }

    /// The previous port, when nothing is listening on it any more — reusing it is what lets a
    /// surviving TUI reconnect by itself.
    static func reusablePort(_ port: Int?) -> Int? {
        guard let port, canBind(port) else { return nil }
        return port
    }

    static func freePort() -> Int? {
        for _ in 0..<20 {
            let port = Int.random(in: 41_000...48_999)
            if canBind(port) { return port }
        }
        return nil
    }

    static func canBind(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func newPassword() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            // The password guards a server that can run shell commands as this user.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            Self.logger.error("could not save OpenCode server state: \(String(describing: error), privacy: .public)")
        }
    }
}
