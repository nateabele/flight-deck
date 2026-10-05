import Foundation

// The `flightdeck` CLI ↔ app half of delegated execution (spec §5), on the control socket.
// The app relays to hosts with HostKit's `DelegationRequest`; this is what a session shell
// says to the app, which is a different contract: a shell never talks to a host itself.
//
//   FleetRequest.delegate(DelegateRequest)   {"op":…, …} inside `req`
//     delegate.run / .exec / .up  {"run":{WireDelegateRun}}
//     delegate.down / .restart / .sync  {service, cwd}
//     delegate.ps                 {}
//     delegate.wait               {run, timeout?, from?}   seconds; absent = the CLI's default
//     delegate.logs               {run, follow, from?}     from: output byte offset to resume at
//     delegate.stop / .diff / .apply  {run}
//     recipe.ls / recipe.check    {cwd}
//     recipe.add                  {cwd, name, recipe:{WireRecipe}}
//     host.disk                   {host}           `host ls --disk`
//     host.prune                  {host, repo?}    `host prune`; no repo = the whole workspace
//   (`host.list` / `host.info` already exist, in `FleetRequest` itself.)
//
//   Replies, all `ServerFrame`s correlated by `cid`, all undotted tags:
//     delegateStarted  {run:{runID, host, ports:[{local, remote}]}}
//                                                 run/exec/up/restart accepted; `ports` are the
//                                                 forwards as bound, so `auto:R` prints its port
//     delegateNotice   {message}                  "waiting for mini's screen — held by …"
//     delegateOutput   {stream, offset, data(base64)}  stream "stdout" | "stderr" | "pty";
//                                                 offset: the run's output byte offset of `data`
//     delegateExit     {status}                   the CLI's exit status, already mapped
//                                                 (code, 128+signal)
//     delegateRuns     {runs:[WireDelegateRunRow]}   ps
//     delegatePatch    {patch:{runID, patch?, patchPath?}}  diff
//     delegateApplied  {applied:{runID, conflicts}}  apply
//     recipes          {recipes:{WireRecipeBook}}    recipe.ls
//     recipeCheck      {problems:[string]}           recipe.check; [] is valid
//     hostDisk         {usage:[{repoRoot, worktreeName, bytes}]}  host.disk
//   `ack` answers stop, down, sync, recipe.add and host.prune. A delegation failure is
//   `err(code, message)`, the message being the §5 one-line hint the CLI prints after
//   `flightdeck: ` and exits 125 on; a `wait` that outlives its timeout is
//   `err(code: "wait_timeout")`, which the CLI exits 124 on.
//
// Streams. `run`, `exec`, `up`, `restart`, `wait` and `logs` may draw many frames on one `cid`;
// the stream ends at its terminal frame, after which nothing more is sent on that `cid`:
//   - `delegateExit`, the run ended;
//   - `err`, it failed (before or during the run);
//   - `delegateStarted`, but only when `--detach` or the recipe's `long` is set: the CLI
//     prints the run id and exits 0, leaving the run going. Otherwise `delegateStarted` is
//     just the first frame of the stream.
// Every other request is answered by exactly one frame.
//
// `delegateOutput.offset` lets a CLI that lost the app (a relaunch, a swap) resume with
// `delegate.logs {from}` or `delegate.wait {from}` without repeating or dropping a byte.
//
// `--pty` is output-only in v1: the run writes to a terminal on the host, but the CLI forwards
// no stdin and never resizes it after start; `columns`/`rows` size it once.
//
// A patch over 1 MiB comes back as `patchPath`, a file the app wrote under
// `Application Support/Flight Deck/delegation/<run>.patch`, instead of inline `patch`: a
// multi-megabyte JSON string on the control socket stalls every other reply behind it.
//
// Every one of these frames is sent only on the connection that asked, and only the local CLI
// asks: the phone app never sends a `delegate.*` request, so an installed phone that cannot
// decode these tags never receives one.
//
// Strings rather than enums for every value a newer Mac may extend (`stream`, `state`, `kind`,
// `apply`), for `WireSession.agent`'s reason: a client-side enum throws on a value added after
// the client shipped. FleetKit does not link HostKit (it compiles for the phone), so the
// recipe and port shapes here are copies of HostKit's, not those types.

/// A `flightdeck` delegation subcommand, as `FleetRequest.delegate`.
///
/// The calling session is not in the request: the app reads it from the control-socket
/// token (`FLIGHT_DECK_CALLER`), which the caller cannot forge for another tab. A human shell
/// has none, and its runs belong to no tab.
public enum DelegateRequest: Codable, Equatable, Sendable {
    /// `flightdeck run`: preflight, sync, run, stream.
    case run(WireDelegateRun)
    /// `flightdeck exec`: run in the host's existing checkout, without syncing.
    case exec(WireDelegateRun)
    /// `flightdeck up`: start a background service.
    case up(WireDelegateRun)
    /// `service` is a run id or the recipe name of a service this session started; `cwd`
    /// picks the project a recipe name is resolved in.
    case down(service: String, cwd: String)
    case restart(service: String, cwd: String)
    /// Re-apply the current snapshot to the service's pinned checkout.
    case sync(service: String, cwd: String)
    /// This session's runs and services (every one, for a human shell).
    case ps
    /// Block until `run` ends; `timeout` in seconds, nil for the CLI's default (9 min).
    /// `from` resumes the output at that byte offset; nil replays it from the start.
    case wait(run: String, timeout: Int?, from: Int64?)
    case logs(run: String, follow: Bool, from: Int64?)
    case stop(run: String)
    case diff(run: String)
    case apply(run: String)
    case recipeList(cwd: String)
    case recipeAdd(cwd: String, name: String, recipe: WireRecipe)
    case recipeCheck(cwd: String)
    /// `flightdeck host ls --disk`: disk use of this Mac's workspace on `host`.
    case hostDisk(host: String)
    /// `flightdeck host prune`: delete this Mac's workspace on `host`, or only `repo`'s.
    case hostPrune(host: String, repo: String?)

    /// True for the requests that change nothing anywhere: listing, replaying and reviewing.
    /// `ControlScope` lets these through at every level; the rest start, stop, or apply work.
    public var isReadOnly: Bool {
        switch self {
        case .ps, .logs, .diff, .recipeList, .hostDisk: return true
        case .run, .exec, .up, .down, .restart, .sync, .wait, .stop, .apply, .recipeAdd, .recipeCheck,
             .hostPrune:
            return false
        }
    }

    private enum Op: String, Codable {
        case run = "delegate.run"
        case exec = "delegate.exec"
        case up = "delegate.up"
        case down = "delegate.down"
        case restart = "delegate.restart"
        case sync = "delegate.sync"
        case ps = "delegate.ps"
        case wait = "delegate.wait"
        case logs = "delegate.logs"
        case stop = "delegate.stop"
        case diff = "delegate.diff"
        case apply = "delegate.apply"
        case recipeList = "recipe.ls"
        case recipeAdd = "recipe.add"
        case recipeCheck = "recipe.check"
        case hostDisk = "host.disk"
        case hostPrune = "host.prune"
    }

    enum CodingKeys: String, CodingKey { case op, run, service, cwd, timeout, follow, name, recipe, from, host, repo }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .run(let run):
            try c.encode(Op.run, forKey: .op)
            try c.encode(run, forKey: .run)
        case .exec(let run):
            try c.encode(Op.exec, forKey: .op)
            try c.encode(run, forKey: .run)
        case .up(let run):
            try c.encode(Op.up, forKey: .op)
            try c.encode(run, forKey: .run)
        case .down(let service, let cwd):
            try c.encode(Op.down, forKey: .op)
            try c.encode(service, forKey: .service)
            try c.encode(cwd, forKey: .cwd)
        case .restart(let service, let cwd):
            try c.encode(Op.restart, forKey: .op)
            try c.encode(service, forKey: .service)
            try c.encode(cwd, forKey: .cwd)
        case .sync(let service, let cwd):
            try c.encode(Op.sync, forKey: .op)
            try c.encode(service, forKey: .service)
            try c.encode(cwd, forKey: .cwd)
        case .ps:
            try c.encode(Op.ps, forKey: .op)
        case .wait(let run, let timeout, let from):
            try c.encode(Op.wait, forKey: .op)
            try c.encode(run, forKey: .run)
            try c.encodeIfPresent(timeout, forKey: .timeout)
            try c.encodeIfPresent(from, forKey: .from)
        case .logs(let run, let follow, let from):
            try c.encode(Op.logs, forKey: .op)
            try c.encode(run, forKey: .run)
            try c.encode(follow, forKey: .follow)
            try c.encodeIfPresent(from, forKey: .from)
        case .stop(let run):
            try c.encode(Op.stop, forKey: .op)
            try c.encode(run, forKey: .run)
        case .diff(let run):
            try c.encode(Op.diff, forKey: .op)
            try c.encode(run, forKey: .run)
        case .apply(let run):
            try c.encode(Op.apply, forKey: .op)
            try c.encode(run, forKey: .run)
        case .recipeList(let cwd):
            try c.encode(Op.recipeList, forKey: .op)
            try c.encode(cwd, forKey: .cwd)
        case .recipeAdd(let cwd, let name, let recipe):
            try c.encode(Op.recipeAdd, forKey: .op)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(name, forKey: .name)
            try c.encode(recipe, forKey: .recipe)
        case .recipeCheck(let cwd):
            try c.encode(Op.recipeCheck, forKey: .op)
            try c.encode(cwd, forKey: .cwd)
        case .hostDisk(let host):
            try c.encode(Op.hostDisk, forKey: .op)
            try c.encode(host, forKey: .host)
        case .hostPrune(let host, let repo):
            try c.encode(Op.hostPrune, forKey: .op)
            try c.encode(host, forKey: .host)
            try c.encodeIfPresent(repo, forKey: .repo)
        }
    }

    /// An unknown `op` throws, as `FleetRequest`'s does, for its reason.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .run: self = .run(try c.decode(WireDelegateRun.self, forKey: .run))
        case .exec: self = .exec(try c.decode(WireDelegateRun.self, forKey: .run))
        case .up: self = .up(try c.decode(WireDelegateRun.self, forKey: .run))
        case .down:
            self = .down(service: try c.decode(String.self, forKey: .service),
                         cwd: try c.decode(String.self, forKey: .cwd))
        case .restart:
            self = .restart(service: try c.decode(String.self, forKey: .service),
                            cwd: try c.decode(String.self, forKey: .cwd))
        case .sync:
            self = .sync(service: try c.decode(String.self, forKey: .service),
                         cwd: try c.decode(String.self, forKey: .cwd))
        case .ps: self = .ps
        case .wait:
            self = .wait(run: try c.decode(String.self, forKey: .run),
                         timeout: try c.decodeIfPresent(Int.self, forKey: .timeout),
                         from: try c.decodeIfPresent(Int64.self, forKey: .from))
        case .logs:
            self = .logs(run: try c.decode(String.self, forKey: .run),
                         follow: try c.decodeIfPresent(Bool.self, forKey: .follow) ?? false,
                         from: try c.decodeIfPresent(Int64.self, forKey: .from))
        case .stop: self = .stop(run: try c.decode(String.self, forKey: .run))
        case .diff: self = .diff(run: try c.decode(String.self, forKey: .run))
        case .apply: self = .apply(run: try c.decode(String.self, forKey: .run))
        case .recipeList: self = .recipeList(cwd: try c.decode(String.self, forKey: .cwd))
        case .recipeAdd:
            self = .recipeAdd(cwd: try c.decode(String.self, forKey: .cwd),
                              name: try c.decode(String.self, forKey: .name),
                              recipe: try c.decode(WireRecipe.self, forKey: .recipe))
        case .recipeCheck: self = .recipeCheck(cwd: try c.decode(String.self, forKey: .cwd))
        case .hostDisk: self = .hostDisk(host: try c.decode(String.self, forKey: .host))
        case .hostPrune:
            self = .hostPrune(host: try c.decode(String.self, forKey: .host),
                              repo: try c.decodeIfPresent(String.self, forKey: .repo))
        }
    }
}

/// One `run`, `exec` or `up` invocation, as the CLI parsed it. Nothing here is resolved yet:
/// the host, the recipe and the ports are all resolved by the app (§5 host resolution order),
/// because only the app holds the registry and reads `delegate.toml`.
public struct WireDelegateRun: Codable, Equatable, Sendable {
    /// The CLI's absolute working directory: the app finds the worktree and the run's subdir
    /// from it.
    public var cwd: String
    /// `--on`.
    public var host: String?
    /// The recipe named on the command line, if any.
    public var recipe: String?
    /// The argv after `--`: the command, or a recipe's extra arguments. Kept as argv rather
    /// than a joined string so route globs (§8) and quoting are the app's single decision.
    public var command: [String]
    /// `--include` paths, `--fetch` globs, `--env K=V`, `--port L:R`.
    public var include: [String]
    public var fetch: [String]
    public var env: [String: String]
    public var ports: [String]
    public var pty: Bool
    public var screen: Bool
    public var detach: Bool
    /// The CLI's terminal size when it has one, for `--pty`.
    public var columns: Int?
    public var rows: Int?

    public init(cwd: String, host: String? = nil, recipe: String? = nil, command: [String] = [],
                include: [String] = [], fetch: [String] = [], env: [String: String] = [:],
                ports: [String] = [], pty: Bool = false, screen: Bool = false, detach: Bool = false,
                columns: Int? = nil, rows: Int? = nil) {
        self.cwd = cwd
        self.host = host
        self.recipe = recipe
        self.command = command
        self.include = include
        self.fetch = fetch
        self.env = env
        self.ports = ports
        self.pty = pty
        self.screen = screen
        self.detach = detach
        self.columns = columns
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case cwd, host, recipe, command, include, fetch, env, ports, pty, screen, detach, columns, rows
    }

    /// Lenient: every flag left off the command line may be absent, so a CLI that never sends
    /// an empty `fetch` is still read the same.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cwd: try c.decode(String.self, forKey: .cwd),
            host: try c.decodeIfPresent(String.self, forKey: .host),
            recipe: try c.decodeIfPresent(String.self, forKey: .recipe),
            command: try c.decodeIfPresent([String].self, forKey: .command) ?? [],
            include: try c.decodeIfPresent([String].self, forKey: .include) ?? [],
            fetch: try c.decodeIfPresent([String].self, forKey: .fetch) ?? [],
            env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            ports: try c.decodeIfPresent([String].self, forKey: .ports) ?? [],
            pty: try c.decodeIfPresent(Bool.self, forKey: .pty) ?? false,
            screen: try c.decodeIfPresent(Bool.self, forKey: .screen) ?? false,
            detach: try c.decodeIfPresent(Bool.self, forKey: .detach) ?? false,
            columns: try c.decodeIfPresent(Int.self, forKey: .columns),
            rows: try c.decodeIfPresent(Int.self, forKey: .rows))
    }
}

/// A run the app accepted: what `--detach` prints, and what a streaming CLI forwards Ctrl-C to.
public struct WireDelegateStarted: Codable, Equatable, Sendable {
    public let runID: String
    /// The host's registry name, as resolved.
    public let host: String
    /// The forwards as bound: `up` with `auto:R` must print the local port it chose, or the
    /// agent has no way to reach the service.
    public let ports: [WirePortBinding]

    public init(runID: String, host: String, ports: [WirePortBinding] = []) {
        self.runID = runID
        self.host = host
        self.ports = ports
    }

    enum CodingKeys: String, CodingKey { case runID, host, ports }

    /// Lenient on `ports`, which C0's shape lacked.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(runID: try c.decode(String.self, forKey: .runID),
                  host: try c.decode(String.self, forKey: .host),
                  ports: try c.decodeIfPresent([WirePortBinding].self, forKey: .ports) ?? [])
    }
}

/// One bound forward: local port on the Mac's 127.0.0.1 to `remote` on the host.
public struct WirePortBinding: Codable, Equatable, Sendable {
    public let local: UInt16
    public let remote: UInt16

    public init(local: UInt16, remote: UInt16) {
        self.local = local
        self.remote = remote
    }
}

/// One row of `flightdeck ps`.
public struct WireDelegateRunRow: Codable, Equatable, Sendable {
    public let runID: String
    public let host: String
    /// The command as run (a recipe's `run`, or the joined argv).
    public let command: String
    public let recipe: String?
    /// "run" | "service".
    public let kind: String
    /// "queued" | "running" | "exited" | "died".
    public let state: String
    /// The CLI exit status once ended (code, or 128+signal).
    public let status: Int32?
    /// Forwards, in `L:R` notation with `L` resolved.
    public let ports: [String]
    public let startedAt: Date?

    public init(runID: String, host: String, command: String, recipe: String?, kind: String,
                state: String, status: Int32?, ports: [String], startedAt: Date?) {
        self.runID = runID
        self.host = host
        self.command = command
        self.recipe = recipe
        self.kind = kind
        self.state = state
        self.status = status
        self.ports = ports
        self.startedAt = startedAt
    }
}

/// A run's changed-file patch, for `flightdeck diff`. Exactly one of `patch` (inline `git diff`
/// text, empty when the run changed nothing) and `patchPath` (a file the app wrote, for a patch
/// over 1 MiB) is set; both are optional so either can be omitted on the wire.
public struct WireDelegatePatch: Codable, Equatable, Sendable {
    public let runID: String
    public let patch: String?
    /// `Application Support/Flight Deck/delegation/<run>.patch`, absolute.
    public let patchPath: String?

    public init(runID: String, patch: String? = nil, patchPath: String? = nil) {
        self.runID = runID
        self.patch = patch
        self.patchPath = patchPath
    }
}

/// One checkout's disk use on a host, for `flightdeck host ls --disk`. A copy of HostKit's
/// `WorkspaceUsage`, for the reason the file header gives.
public struct WireWorkspaceUsage: Codable, Equatable, Sendable {
    public let repoRoot: String
    public let worktreeName: String
    public let bytes: Int64

    public init(repoRoot: String, worktreeName: String, bytes: Int64) {
        self.repoRoot = repoRoot
        self.worktreeName = worktreeName
        self.bytes = bytes
    }
}

/// The outcome of `flightdeck apply`: the paths left with conflict markers, empty when clean.
public struct WireDelegateApplied: Codable, Equatable, Sendable {
    public let runID: String
    public let conflicts: [String]

    public init(runID: String, conflicts: [String]) {
        self.runID = runID
        self.conflicts = conflicts
    }
}

/// HostKit's `Recipe`, copied for the reason the file header gives, plus its `name`.
public struct WireRecipe: Codable, Equatable, Sendable {
    public var name: String
    public var host: String?
    public var run: String
    public var down: String?
    public var screen: Bool
    public var long: Bool
    public var service: Bool
    public var restartOnSync: Bool
    public var fetch: [String]
    public var ports: [String]
    public var env: [String: String]
    /// "review" | "auto".
    public var apply: String
    public var pool: Int?

    public init(name: String, host: String? = nil, run: String, down: String? = nil,
                screen: Bool = false, long: Bool = false, service: Bool = false,
                restartOnSync: Bool = false, fetch: [String] = [], ports: [String] = [],
                env: [String: String] = [:], apply: String = "review", pool: Int? = nil) {
        self.name = name
        self.host = host
        self.run = run
        self.down = down
        self.screen = screen
        self.long = long
        self.service = service
        self.restartOnSync = restartOnSync
        self.fetch = fetch
        self.ports = ports
        self.env = env
        self.apply = apply
        self.pool = pool
    }

    enum CodingKeys: String, CodingKey {
        case name, host, run, down, screen, long, service, restartOnSync, fetch, ports, env, apply, pool
    }

    /// Lenient, as HostKit's `Recipe` is: an absent field is its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            host: try c.decodeIfPresent(String.self, forKey: .host),
            run: try c.decode(String.self, forKey: .run),
            down: try c.decodeIfPresent(String.self, forKey: .down),
            screen: try c.decodeIfPresent(Bool.self, forKey: .screen) ?? false,
            long: try c.decodeIfPresent(Bool.self, forKey: .long) ?? false,
            service: try c.decodeIfPresent(Bool.self, forKey: .service) ?? false,
            restartOnSync: try c.decodeIfPresent(Bool.self, forKey: .restartOnSync) ?? false,
            fetch: try c.decodeIfPresent([String].self, forKey: .fetch) ?? [],
            ports: try c.decodeIfPresent([String].self, forKey: .ports) ?? [],
            env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            apply: try c.decodeIfPresent(String.self, forKey: .apply) ?? "review",
            pool: try c.decodeIfPresent(Int.self, forKey: .pool))
    }
}

public struct WireRoute: Codable, Equatable, Sendable {
    public let match: String
    public let recipe: String

    public init(match: String, recipe: String) {
        self.match = match
        self.recipe = recipe
    }
}

/// A project's whole `delegate.toml`, for `flightdeck recipe ls`. Recipes sorted by name, so
/// two listings of one file print identically.
public struct WireRecipeBook: Codable, Equatable, Sendable {
    public let defaultHost: String?
    public let include: [String]
    public let recipes: [WireRecipe]
    public let routes: [WireRoute]

    public init(defaultHost: String?, include: [String], recipes: [WireRecipe], routes: [WireRoute]) {
        self.defaultHost = defaultHost
        self.include = include
        self.recipes = recipes
        self.routes = routes
    }
}
