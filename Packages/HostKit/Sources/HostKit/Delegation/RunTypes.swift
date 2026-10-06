import Foundation

// Runs (spec §6): a command in its own process group on the host, with its output spooled so
// a dropped controller can reattach from an offset. Implemented by track C3; the host router
// and `DelegationService` consume it. Codecs for the enums live in `DelegationWire.swift`.

/// What to run, as the controller resolved it from the CLI and the recipe.
public struct RunSpec: Codable, Sendable, Equatable {
    /// Run as `$SHELL -lc '<command>'` (§6.1).
    public var command: String
    /// The CLI's working directory relative to its worktree root; "" for the root itself.
    public var subdir: String
    /// `--env` plus recipe `env` only. The controller's own environment is never sent (§2.2).
    public var env: [String: String]
    public var pty: Bool
    /// Needs the host's single screen lease (§6.3).
    public var screen: Bool
    /// A long-lived service pinned to its checkout slot (§6.2).
    public var service: Bool
    /// The recipe's `down` command, run after SIGTERM on `down`.
    public var downCommand: String?
    /// For a service: the remote ports it is expected to serve.
    public var ports: [PortMapping]
    /// The CLI's terminal size, for `--pty` when the CLI has a terminal; nil otherwise.
    /// `--pty` is output-only in v1: the run gets a terminal to write to (colour, progress
    /// bars), but no stdin is forwarded and the size is never updated after start.
    public var ptySize: TerminalSize?
    /// `--fetch` plus recipe `fetch` globs. The host captures them at exit, before it releases
    /// the slot, because the next run in that slot would otherwise overwrite them before the
    /// controller asks with `run.artifacts`.
    public var fetch: [String]
    /// The recipe's `pool`: this worktree's checkout slots (§4.6); nil for the default of 2.
    public var pool: Int?
    /// For a service: seconds with no controller connected before the host runs `down`
    /// itself (§6.2, default 30 min); nil for the host default.
    public var orphanTimeout: Int?

    public init(command: String, subdir: String, env: [String: String], pty: Bool, screen: Bool,
                service: Bool, downCommand: String?, ports: [PortMapping], ptySize: TerminalSize? = nil,
                fetch: [String] = [], pool: Int? = nil, orphanTimeout: Int? = nil) {
        self.command = command
        self.subdir = subdir
        self.env = env
        self.pty = pty
        self.screen = screen
        self.service = service
        self.downCommand = downCommand
        self.ports = ports
        self.ptySize = ptySize
        self.fetch = fetch
        self.pool = pool
        self.orphanTimeout = orphanTimeout
    }

    // Explicit raw values: a Swift rename must not change the wire. Optionals are omitted
    // when nil (synthesized `encodeIfPresent`), pinned in `DelegationWireTests`.
    enum CodingKeys: String, CodingKey {
        case command = "command"
        case subdir = "subdir"
        case env = "env"
        case pty = "pty"
        case screen = "screen"
        case service = "service"
        case downCommand = "downCommand"
        case ports = "ports"
        case ptySize = "ptySize"
        case fetch = "fetch"
        case pool = "pool"
        case orphanTimeout = "orphanTimeout"
    }

    /// Lenient past the first wire version: `command` through `ports` are required, and every
    /// field added since is `decodeIfPresent`, so a 1.1 peer built before it still decodes.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(command: try c.decode(String.self, forKey: .command),
                  subdir: try c.decode(String.self, forKey: .subdir),
                  env: try c.decode([String: String].self, forKey: .env),
                  pty: try c.decode(Bool.self, forKey: .pty),
                  screen: try c.decode(Bool.self, forKey: .screen),
                  service: try c.decode(Bool.self, forKey: .service),
                  downCommand: try c.decodeIfPresent(String.self, forKey: .downCommand),
                  ports: try c.decode([PortMapping].self, forKey: .ports),
                  ptySize: try c.decodeIfPresent(TerminalSize.self, forKey: .ptySize),
                  fetch: try c.decodeIfPresent([String].self, forKey: .fetch) ?? [],
                  pool: try c.decodeIfPresent(Int.self, forKey: .pool),
                  orphanTimeout: try c.decodeIfPresent(Int.self, forKey: .orphanTimeout))
    }
}

public struct TerminalSize: Codable, Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case columns = "columns"
        case rows = "rows"
    }
}

/// One thing that happened to a run, in order. Carried to the controller as
/// `HostServerFrame.event(runID:_:)`.
public enum RunEvent: Sendable, Equatable {
    /// Waiting for the screen lease or a checkout slot, as `on` says. `holder` is the run in
    /// the way, for the CLI's "waiting for mini's screen — held by …" line; nil when the host
    /// cannot name one.
    case queued(position: Int, on: WaitReason, holder: LeaseHolder?)
    case started(runID: String)
    /// `offset` is the byte offset of `data` in this run's spooled output, across all its
    /// streams, so a reattach `from:` an offset neither loses nor repeats a byte.
    case output(stream: RunOutputStream, offset: Int64, data: Data)
    case exited(RunExit)
    /// A service ended without being asked to (§6.2).
    case serviceDied(RunExit)
}

/// Not `OutputStream`: Foundation already has a type by that name, and every file importing
/// both Foundation and HostKit (all of them) would then fail with "ambiguous for type lookup".
public enum RunOutputStream: String, Codable, Sendable {
    case stdout = "stdout"
    case stderr = "stderr"
    case pty = "pty"
}

public enum RunExit: Sendable, Equatable {
    case code(Int32)
    case signal(Int32)

    /// What `flightdeck run` exits with (§5): the code itself, or `128+n` for signal `n`, the
    /// shell's convention, so an agent reading `$?` cannot tell a delegated run from a local one.
    public var cliStatus: Int32 {
        switch self {
        case .code(let code): return code
        case .signal(let signal): return 128 + signal
        }
    }
}

/// What a queued run is waiting for.
public enum WaitReason: String, Codable, Sendable {
    case screen = "screen"
    case slot = "slot"
}

/// The run holding what another waits on. `session` is the owning tab's display title, never
/// a token or an internal id: it is printed to another session's agent.
public struct LeaseHolder: Codable, Sendable, Equatable {
    public let runID: String
    public let session: String

    public init(runID: String, session: String) {
        self.runID = runID
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case runID = "runID"
        case session = "session"
    }
}

/// Who started a run: the paired controller (from the connection, never the request) and the
/// session's display title (from `run.start`'s `owner`). Host-local, so not `Codable`.
public struct LeaseHolderOwner: Sendable, Equatable {
    public let controller: UUID
    public let session: String

    public init(controller: UUID, session: String) {
        self.controller = controller
        self.session = session
    }
}

/// The host's runner (track C3).
public protocol RunControlling: Sendable {
    /// Registers `spec` and returns its run id at once, before it holds a slot: a run waiting
    /// on the screen or a busy pool must already be nameable, so the controller can attach,
    /// show "queued" and cancel it. The runner calls `acquire` when the run reaches the head
    /// of its queue, runs in the lease it returns, and releases that lease when the run ends.
    func start(_ spec: RunSpec, owner: LeaseHolderOwner,
               acquire: @escaping @Sendable () async throws -> CheckoutLease) -> String
    /// Replays the current state (`queued` or `started`), then output from byte `offset` of
    /// the spool, then `exited` if the run has finished; live events follow until exit.
    func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error>
    func signal(runID: String, _ sig: Int32) throws
    /// SIGINT to the group, SIGTERM after 10 s, SIGKILL after another 10 s. A run still
    /// queued is dropped from its queue and never starts.
    func cancel(runID: String)
    /// Stops a service: SIGTERM, await its exit, then its `downCommand` in the same checkout.
    /// An asked-for stop never emits `serviceDied`.
    func down(runID: String) async throws
    /// Who started `runID`, or nil for an unknown run. The router checks it before `events`,
    /// `signal`, `cancel` and `down`, and answers another controller's run `unknown_run`, so
    /// one paired Mac can neither see nor stop another's work.
    func owner(runID: String) -> LeaseHolderOwner?
    /// `controller`'s runs that are still queued or running, services included. Revoking a
    /// controller ends exactly these.
    func liveRuns(controller: UUID) -> [String]
    /// hostd is stopping: every service is downed (`downCommand` included) and every other run
    /// ended, SIGTERM now and SIGKILL to any group still alive after `grace` seconds. Returns
    /// once every run has ended, or after `deadline` seconds, whichever is first; a run that
    /// starts meanwhile fails at once. Nothing else would end them: each run leads its own
    /// process group, and launchd and a plain `kill` signal only hostd's.
    func shutdown(grace: Double, deadline: Double) async
}

/// The host's screen, for `screen.status` and the §7 preflight.
public struct ScreenStatus: Codable, Sendable, Equatable {
    /// False on Linux, where `screen` is refused in v1.
    public var supported: Bool
    /// A console user is logged in (macOS: `CGSessionCopyCurrentDictionary`).
    public var consoleUser: Bool
    public var locked: Bool
    /// The run holding the lease, if any.
    public var holder: LeaseHolder?
    /// How many runs are waiting for it.
    public var queued: Int

    public init(supported: Bool, consoleUser: Bool, locked: Bool, holder: LeaseHolder?, queued: Int) {
        self.supported = supported
        self.consoleUser = consoleUser
        self.locked = locked
        self.holder = holder
        self.queued = queued
    }

    enum CodingKeys: String, CodingKey {
        case supported = "supported"
        case consoleUser = "consoleUser"
        case locked = "locked"
        case holder = "holder"
        case queued = "queued"
    }

    /// Lenient past the first wire version, as `RunSpec` is: a field added later must be read
    /// with `decodeIfPresent`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(supported: try c.decode(Bool.self, forKey: .supported),
                  consoleUser: try c.decode(Bool.self, forKey: .consoleUser),
                  locked: try c.decode(Bool.self, forKey: .locked),
                  holder: try c.decodeIfPresent(LeaseHolder.self, forKey: .holder),
                  queued: try c.decode(Int.self, forKey: .queued))
    }
}
