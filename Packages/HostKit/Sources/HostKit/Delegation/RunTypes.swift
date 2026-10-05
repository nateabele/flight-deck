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
    public var ptySize: TerminalSize?

    public init(command: String, subdir: String, env: [String: String], pty: Bool, screen: Bool,
                service: Bool, downCommand: String?, ports: [PortMapping], ptySize: TerminalSize? = nil) {
        self.command = command
        self.subdir = subdir
        self.env = env
        self.pty = pty
        self.screen = screen
        self.service = service
        self.downCommand = downCommand
        self.ports = ports
        self.ptySize = ptySize
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
    /// Waiting for the screen lease (or a pool slot). `holder` names what it waits on, for the
    /// CLI's "waiting for mini's screen — held by …" line.
    case queued(position: Int, holder: String?)
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

/// The host's runner (track C3).
public protocol RunControlling: Sendable {
    /// Starts (or queues) `spec` in `lease`'s checkout and returns its run id. `owner` names
    /// the controller session for the screen-queue message and service ownership.
    func start(_ spec: RunSpec, in lease: CheckoutLease, owner: String) async throws -> String
    /// Every event from byte `offset` of the spooled output on, then live ones until exit.
    func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error>
    func signal(runID: String, _ sig: Int32) throws
    /// SIGINT to the group, SIGTERM after 10 s, SIGKILL after another 10 s.
    func cancel(runID: String)
}

/// The host's screen, for `screen.status` and the §7 preflight.
public struct ScreenStatus: Codable, Sendable, Equatable {
    /// False on Linux, where `screen` is refused in v1.
    public var supported: Bool
    /// A console user is logged in (macOS: `CGSessionCopyCurrentDictionary`).
    public var consoleUser: Bool
    public var locked: Bool
    /// The run holding the lease, if any.
    public var holder: String?
    /// How many runs are waiting for it.
    public var queued: Int

    public init(supported: Bool, consoleUser: Bool, locked: Bool, holder: String?, queued: Int) {
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
}
