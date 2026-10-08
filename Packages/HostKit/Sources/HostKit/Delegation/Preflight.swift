import Foundation

// Preflight (spec §7): every `run` and `up` checks everything that can fail before any sync
// or remote work, so a doomed run changes nothing on either machine. The pipeline is pure
// over `PreflightChecks`; the app supplies the real checks (config, HostLink, PortForwarder,
// git) and tests supply recording fakes.

/// A delegation failure. `description` is the finished 125 line (`flightdeck: …`); the CLI
/// prints it as-is and exits 125. `code` is one of A5's host codes or A5b's controller
/// preflight codes (both pinned in `DelegationWire.swift`). `message` names the host or port
/// and then, after " — ", the next step: the reader is usually an agent that can only act on
/// what the line tells it.
public struct DelegationError: Error, Equatable, Sendable, CustomStringConvertible {
    public static let exitStatus: Int32 = 125

    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "flightdeck: \(message)" }

    /// Step 4, the spec's example with the shared " — " joiner: `localhost:5432 is held by
    /// postgres (pid 812) — try --port 15433:5432 or --port auto:5432`.
    public static func localPortHeld(local: UInt16, remote: UInt16, holder: PortHolder, suggestion: UInt16?) -> DelegationError {
        let tries = (suggestion.map { ["--port \($0):\(remote)"] } ?? []) + ["--port auto:\(remote)"]
        return DelegationError(code: "local_port_held",
                               message: "localhost:\(local) is held by \(describe(holder)) — try \(tries.joined(separator: " or "))")
    }

    /// Step 4 when nothing listens but the bind still fails: our own forward's connections,
    /// closed by us first, leave the port in TIME_WAIT for ~30 s after a `down`, and Network
    /// framework cannot bind over that.
    public static func localPortInTimeWait(local: UInt16, remote: UInt16) -> DelegationError {
        DelegationError(code: "local_port_held",
                        message: "localhost:\(local) was just released and is still in TIME_WAIT — retry shortly or use --port auto:\(remote)")
    }

    /// Step 5. The remote port is the service's own, so the way out is on the host.
    public static func remotePortHeld(host: String, port: UInt16, holder: PortHolder) -> DelegationError {
        let stop: String
        switch holder {
        case .container(let name): stop = "stop it on \(host) (docker stop \(name))"
        case .flightDeck: stop = "stop that service with flightdeck down"
        default: stop = "stop it on \(host)"
        }
        return DelegationError(code: "port_held",
                               message: "\(host):\(port) is held by \(describe(holder)) — \(stop), or change the recipe's remote port")
    }

    static func describe(_ holder: PortHolder) -> String {
        switch holder {
        case .process(let name, let pid): return "\(name) (pid \(pid))"
        case .container(let name): return "Docker container \"\(name)\""
        case .flightDeck(let session): return "Flight Deck session \"\(session)\""
        case .free, .unknown: return "another process"
        }
    }
}

/// What step 1 resolved: everything the later steps check. `ports` is already merged
/// (`Preflight.mergePorts`); `sync` is false for `exec`, which runs in the existing checkout.
public struct PreflightPlan: Sendable, Equatable {
    public var host: String
    public var ports: [PortMapping]
    public var screen: Bool
    public var service: Bool
    public var sync: Bool
    public var include: [String]
    public var fetch: [String]

    public init(host: String, ports: [PortMapping], screen: Bool, service: Bool, sync: Bool,
                include: [String] = [], fetch: [String] = []) {
        self.host = host
        self.ports = ports
        self.screen = screen
        self.service = service
        self.sync = sync
        self.include = include
        self.fetch = fetch
    }

    /// What the host must advertise for this plan (step 2). A pty needs nothing beyond `run`.
    public var requiredCapabilities: [HostCapability] {
        [.run] + (sync ? [.sync] : []) + (service || !ports.isEmpty ? [.service] : []) + (screen ? [.screen] : [])
    }
}

/// One held local forward after step 4, with `auto` resolved to the port actually bound.
public struct PortForward: Sendable, Equatable {
    public let local: UInt16
    public let remote: UInt16

    public init(local: UInt16, remote: UInt16) {
        self.local = local
        self.remote = remote
    }
}

/// Local listeners bound at step 4 and held until `release`. Holding (not just checking) is
/// the point: a port checked free and bound later can be taken in between by anything,
/// including a second preflight in another tab.
public protocol PortReservation: AnyObject, Sendable {
    var forwards: [PortForward] { get }
    /// Begin serving: each accepted connection on a forward to remote `R` opens a channel
    /// from `connect(R)`. Before this, connections wait in the listen backlog.
    func startForwarding(_ connect: @escaping @Sendable (_ remote: UInt16) -> any ChannelOpening)
    /// Close every listener. Idempotent.
    func release()
}

/// The seven checks of §7, one method each, called by `Preflight.run` in exactly this order.
/// A method throws a `DelegationError` for a failure it can word itself; anything else is
/// wrapped as `preflight_failed` naming the host.
public protocol PreflightChecks: Sendable {
    /// 1. Resolve the host and recipe; validate `delegate.toml`.
    func resolve() async throws -> PreflightPlan
    /// 2. The host's negotiated capabilities, or nil when it is not connected.
    func hostCapabilities(_ host: String) async throws -> Set<HostCapability>?
    /// 3. Every `include` path exists locally; no `fetch` glob matches a tracked path.
    func checkLocalPaths(_ plan: PreflightPlan) async throws
    /// 4. Bind and hold every local port; throws `DelegationError.localPortHeld` on a conflict,
    ///    having released whatever it had bound so far.
    func reserveLocalPorts(_ ports: [PortMapping], host: String) async throws -> any PortReservation
    /// 5. `port.check` on the host.
    func remotePorts(_ ports: [UInt16], host: String) async throws -> [PortStatus]
    /// 6. `screen.status` on the host.
    func screenStatus(_ host: String) async throws -> ScreenStatus
    /// 7. The LFS check (§4.2 step 5).
    func checkLFS(_ plan: PreflightPlan) async throws
}

/// A passed preflight: the plan and the held local ports. Release it when the run or service
/// ends, or when anything after preflight fails.
public final class Reservation: @unchecked Sendable {
    public let plan: PreflightPlan
    public let ports: (any PortReservation)?
    private let lock = NSLock()
    private var released = false

    init(plan: PreflightPlan, ports: (any PortReservation)?) {
        self.plan = plan
        self.ports = ports
    }

    public var forwards: [PortForward] { ports?.forwards ?? [] }

    /// Idempotent and safe from any thread: a service's `down`, its tab closing and the
    /// orphan path can all race to release one reservation, and only the first may act.
    public func release() {
        let first: Bool = lock.withLock {
            defer { released = true }
            return !released
        }
        if first { ports?.release() }
    }
}

public enum Preflight {
    /// Runs §7 in order. On failure, releases the local ports (if step 4 took them) before
    /// throwing, so nothing stays bound for the retry the error message suggests.
    public static func run(_ checks: some PreflightChecks) async throws -> Reservation {
        var host = "the host"
        var held: (any PortReservation)?
        do {
            let plan = try await checks.resolve()                                       // 1
            host = plan.host

            guard let caps = try await checks.hostCapabilities(host) else {             // 2
                throw DelegationError(code: "host_unavailable",
                                      message: "\(host) is not connected — check flightdeck host ls, and that hostd is running on \(host)")
            }
            let missing = plan.requiredCapabilities.filter { !caps.contains($0) }
            if !missing.isEmpty {
                throw DelegationError(code: "unsupported",
                                      message: "\(host)'s hostd does not support \(missing.map(noun).joined(separator: " and ")) — update Flight Deck on \(host), then retry")
            }

            try await checks.checkLocalPaths(plan)                                       // 3

            if !plan.ports.isEmpty {                                                     // 4
                held = try await checks.reserveLocalPorts(plan.ports, host: host)
            }

            if !plan.ports.isEmpty {                                                     // 5
                let asked = plan.ports.map(\.remote)
                let answers = try await checks.remotePorts(asked, host: host)
                for port in asked {
                    guard let status = answers.first(where: { $0.port == port }) else {
                        // A host that skips a port speaks a `port.check` this controller does
                        // not understand, so it is reported as the op being unsupported.
                        throw DelegationError(code: "unsupported",
                                              message: "\(host) did not check port \(port) — update Flight Deck on \(host), then retry")
                    }
                    if status.holder != .free {
                        throw DelegationError.remotePortHeld(host: host, port: port, holder: status.holder)
                    }
                }
            }

            if plan.screen {                                                             // 6
                if let failure = screenFailure(try await checks.screenStatus(host), host: host) { throw failure }
            }

            try await checks.checkLFS(plan)                                              // 7
            return Reservation(plan: plan, ports: held)
        } catch {
            held?.release()
            if let error = error as? DelegationError { throw error }
            // Cancellation means the caller has gone (the CLI hung up); it must see that to
            // stop, not a 125 line that nobody will read.
            if error is CancellationError { throw error }
            throw DelegationError(code: "preflight_failed", message: "preflight for \(host) failed: \(error) — fix it, then retry")
        }
    }

    /// The lease itself is not checked: a held screen queues (§6.3); only a console nobody can
    /// use fails, because a UI test against a locked screen fails late and confusingly.
    static func screenFailure(_ status: ScreenStatus, host: String) -> DelegationError? {
        if !status.supported {
            return DelegationError(code: "screen_unsupported",
                                   message: "\(host) cannot take screen runs (Linux hosts refuse --screen) — drop --screen or pick a macOS host")
        }
        if !status.consoleUser {
            return DelegationError(code: "no_console_user",
                                   message: "\(host) has no user logged in at the console — log in on \(host)'s screen, then retry")
        }
        if status.locked {
            return DelegationError(code: "screen_locked", message: "\(host)'s screen is locked — unlock it, then retry")
        }
        return nil
    }

    private static func noun(_ cap: HostCapability) -> String {
        switch cap {
        case .hostInfo: return "host info"
        case .run: return "runs"
        case .sync: return "sync"
        case .service: return "services"
        case .screen: return "screen runs"
        case .submodules: return "submodules"
        }
    }

    /// The recipe's `ports` with the CLI's `--port`s applied (§6.2): a CLI entry replaces the
    /// recipe entry for the same remote port in place, and a CLI entry for a new remote port
    /// is appended. A later CLI entry for the same remote wins over an earlier one.
    public static func mergePorts(recipe: [String], cli: [String]) throws -> [PortMapping] {
        func parse(_ s: String) throws -> PortMapping {
            do { return try PortMapping.parse(s) } catch {
                throw DelegationError(code: "invalid_port", message: "\(error)")
            }
        }
        var merged = try recipe.map(parse)
        for mapping in try cli.map(parse) {
            if let i = merged.firstIndex(where: { $0.remote == mapping.remote }) {
                merged[i] = mapping
            } else {
                merged.append(mapping)
            }
        }
        var seen: [UInt16: PortMapping] = [:]
        for mapping in merged {
            guard case .fixed(let local) = mapping.local else { continue }
            if let first = seen[local] {
                throw DelegationError(code: "invalid_port",
                                      message: "local port \(local) is mapped twice (\(first.notation), \(mapping.notation)) — give one of them another local port")
            }
            seen[local] = mapping
        }
        return merged
    }
}
