import FleetKit
import Foundation
import HostKit
import os

// The app half of delegated execution (spec §4–§7): what `flightdeck run`, `up`, `wait`, …
// ask of the control socket, carried out against a paired host.
//
// Every piece that touches git, a socket or a host is behind one of the protocols below, so
// the whole flow — resolve, preflight, sync, start, stream, result — runs in a unit test
// against in-memory fakes. The real ones are under `Live/` (`DelegationServiceFactory` wires
// them): `LiveHostLink` over `HostLink` and its channel mux, and the git, preflight, port
// forwarding and `delegate.toml` adapters.
//
// Streaming (DelegationControlWire.swift's "Streams"): a `run` answers its `cid` with
// `delegateStarted`, any `delegateNotice`s and `delegateOutput`s, and ends it with exactly one
// terminal frame:
//   delegateStarted         only when the request says `detach`, or it is `up`/`restart`: the
//                           CLI decides (`detach = --detach || long || service`), so the two
//                           ends can never disagree about which frame is the last
//   delegateExit {status}   an attached run ended; the CLI exits with `status`
//   err {code, message}     delegation failed (125), the missing-file hint (125), or a
//                           `wait` timeout (`wait_timeout`, 124)

// MARK: - Seams

/// A paired, connected host, as delegation drives it. `LiveHostLink` is the real one, over
/// `HostLink` and its channel mux. A host's `err` reaches here as
/// `HostLinkError.remote(code:message:)`, whose codes `DelegationService.hostLine` turns into
/// the §5 lines.
@MainActor
protocol HostLinking: AnyObject {
    /// The registry name, for every message that names the host.
    var name: String { get }
    /// False once the link has dropped for good. A run's watcher holding a dead link asks
    /// the directory again (`DelegationService.link(for:)`) rather than failing on it forever.
    var isConnected: Bool { get }
    /// One request, answered by its reply; a host error throws (`HostLinkError.remote`).
    func request(_ request: DelegationRequest) async throws -> DelegationReply
    /// A fresh channel whose id a following request names (`sync.push`, `run.result`, …).
    func openChannel() async throws -> any ByteChannel
    /// Every event for the host's `runID` whose output lies at or past byte `offset`, then live
    /// ones until it exits. `localID` is this Mac's id for the same run, which names its copy
    /// on disk. The contract the adapter must keep (Ruling 18: concurrent subscribers share one
    /// host attach, each at its own offset; Ruling 21: a disk copy is the replay source);
    /// `FakeHostLink` keeps the subscription half of it:
    /// - **A disk mirror is the replay source** (Ruling 21). The adapter keeps each run's
    ///   output under `Application Support/Flight Deck/delegation/<localID>.out`, bounded at
    ///   64 MiB per run with the oldest dropped first, as the host spool is. `events(from:)`
    ///   replays from the mirror, then goes live. It attaches to the host only for a range the
    ///   mirror lacks (a fresh install, a range dropped from the mirror). The mirror survives a
    ///   relaunch and is pruned with the registry. So a resume, a `logs`, a `slow_reader`
    ///   reattach cost a local read, not a host round trip.
    /// - **Concurrent subscriptions, independent offsets.** The monitor, an attached `run`, a
    ///   `wait {from}` and a `logs` may all subscribe to one run at once, each from its own
    ///   offset. The adapter keeps ONE host attach per run (`run.start`'s, or `run.attach`)
    ///   and fans its events out locally, so a second subscriber never costs a second attach.
    /// - **Cancellation.** A subscriber's task being cancelled ends its stream and frees it;
    ///   the run, and every other subscriber, carry on.
    /// - **Exact offsets.** A subscriber from `offset` gets no byte before it: a chunk that
    ///   straddles it is cut to start there.
    /// - **Replay order** (A2): the run's current state (`queued`/`started`), then output from
    ///   `offset`, then `exited` if it has finished — a subscriber that arrives after the end
    ///   still gets the whole story, and the stream then finishes.
    /// - **Nothing lost before the first subscriber.** `run.start` attaches at once, so its
    ///   first output can beat the reply naming the run; the adapter buffers it.
    /// - **Reconnect.** After a dropped link it re-sends `run.attach` from the last offset it
    ///   holds, so a laptop that slept mid-run loses nothing and repeats nothing.
    func events(runID: String, localID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error>
}

/// The paired hosts, by name.
@MainActor
protocol DelegationHostDirectory: AnyObject {
    /// Every paired host, for the message that lists them when no host was given.
    var hostNames: [String] { get }
    /// The link to `name`. Throws `DelegationError` with the §5 line when it is unknown or
    /// offline ("mini is offline (last seen 4m ago)").
    func link(named name: String) throws -> any HostLinking
    /// Deletes these runs' output copies and ends anyone still reading them: retention is
    /// letting them go (`DelegationService.pruneExpired`). Works with their host offline.
    func forget(_ runs: [DelegatedRun])
}

/// The cloud machines (`InfraService`), as `run --on` needs them: a `[infra.<name>]` host with
/// `auto_up` is created on the first run aimed at it, and every run on a cloud machine opens
/// with its cost line (spec §8.4).
protocol InfraUpProviding: AnyObject {
    /// Creates `[infra.<name>]` (or takes over the one already running), returning once it is
    /// a paired, online host. `notice` gets each progress line. Throws `DelegationError` with
    /// the `infra_*` code and its finished line.
    @MainActor func ensureUp(name: String, config: InfraConfig, repoRoot: URL,
                             notice: @escaping (String) -> Void) async throws
    /// The §8.4 line for a cloud machine; nil for any other host.
    @MainActor func costLine(host: String) -> String?
}

/// Everything §7 checks, resolved: what the preflight is asked to clear.
struct DelegationPlan {
    let host: String
    let worktree: URL
    let subdir: String
    let spec: RunSpec
    /// Declared ignored files to sync (`include` + `--include`).
    let include: [String]
    /// Artifact globs (`fetch` + `--fetch`); one matching a tracked path is refused (§4.5).
    let fetch: [String]
    /// False for `exec`, which syncs nothing, so §7 step 3 has nothing to check.
    let sync: Bool
}

/// §7 steps 2–7, in order (C5's `Preflight.run` behind it). Throws `DelegationError` whose
/// message is already the finished 125 line; a failure leaves nothing reserved.
protocol Preflighting {
    func preflight(_ plan: DelegationPlan, link: any HostLinking) async throws -> any PortReservation
}

/// How a run's changed files came back, or did not.
enum ApplyOutcome: Equatable {
    case clean
    /// The paths left with conflict markers — or, when conflicts were not allowed, the paths
    /// that would have been, with nothing written.
    case conflicts([String])
    case nothing
}

/// The controller side of §4.5 (C2's `ResultApplier`). Async and nonisolated: each one is git
/// work, awaited off the main actor so a big merge never stalls the UI.
protocol ResultApplying: Sendable {
    /// `git diff` text for `commit` against `snapshot`.
    func patch(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL) async throws -> String
    /// A three-way merge into the **current** worktree with `snapshot` as the base, so edits
    /// made during the run conflict rather than being overwritten. `allowConflicts: false` is
    /// `apply = "auto"`: a conflicting merge writes nothing and reports the paths.
    func apply(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL,
               allowConflicts: Bool) async throws -> ApplyOutcome
    /// Unpacks the artifact tar into the worktree; a file replaces a local one only if ignored.
    func extractArtifacts(tar: URL, into worktree: URL) async throws
}

/// `.flightdeck/delegate.toml` (C4's parser and writer behind it). Route matching is not here:
/// it is C4's `RouteMatcher`, the same rule the CLI's `route-exec` applies.
protocol DelegateConfigLoading {
    /// Nil when the project has no `delegate.toml`, which is not an error: `run --on mini --
    /// make` needs none.
    func load(worktree: URL) throws -> DelegateConfig?
    func add(_ recipe: Recipe, named name: String, worktree: URL) throws
    /// `recipe check`'s findings; empty means valid.
    func problems(in config: DelegateConfig, hosts: [String]) -> [String]
}

/// Finds the worktree a CLI's cwd is in, and asks git about it. Async and nonisolated, so the
/// `git` processes run off the main actor.
protocol WorktreeLocating: Sendable {
    /// The worktree root, and the cwd relative to it ("" at the root).
    func locate(cwd: URL) async throws -> (worktree: URL, subdir: String)
    /// Which of `paths` (worktree-relative) git ignores.
    func ignored(_ paths: [String], in worktree: URL) async -> Set<String>
}

/// A port forward's channel to the host: `port.open` naming a fresh channel, per accepted
/// connection. What `PortReservation.startForwarding` is handed for each remote port.
private final class ServicePortOpener: ChannelOpening, @unchecked Sendable {
    private let link: any HostLinking
    private let service: String
    private let remote: UInt16

    init(link: any HostLinking, service: String, remote: UInt16) {
        self.link = link
        self.service = service
        self.remote = remote
    }

    func open() async throws -> any ByteChannel {
        let channel = try await link.openChannel()
        do {
            _ = try await link.request(.portOpen(service: service, remote: remote, channel: channel.id))
        } catch {
            // A6: a channel named by a failed request is cancelled by both sides.
            channel.cancel()
            throw error
        }
        return channel
    }
}

// MARK: - Service

/// Owns every session's delegated runs and services, and answers the control socket's
/// `delegate.*` and `recipe.*` requests (spec §5).
@MainActor
final class DelegationService {
    struct Dependencies {
        var hosts: any DelegationHostDirectory
        var preflight: any Preflighting
        var snapshots: any SnapshotMaking
        var bundles: any BundleMaking
        var results: any ResultApplying
        var config: any DelegateConfigLoading
        var worktrees: any WorktreeLocating
        /// A tab's title, for the host's screen-queue message ("held by r3 (session "…")").
        var sessionTitle: (UUID) -> String?
        /// `wait`'s clock, injectable so a test's 9-minute timeout takes no time.
        var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
        /// `Application Support/Flight Deck/delegation/`: fetched result bundles until applied,
        /// artifact tars until unpacked, and `<run>.patch` for a `diff` over 1 MiB.
        var directory: URL
        /// How long a `logs` replay of a run this app did not watch waits for the next event
        /// before deciding it has caught up, and how long it waits for the first (see `logs`).
        var replayIdle: TimeInterval = 2
        var replayFirstEvent: TimeInterval = 10
        /// Cloud machines; nil where this Flight Deck has no cloud service, and a
        /// `[infra.<name>]` host then has to be brought up some other way.
        var infra: (any InfraUpProviding)? = nil
    }

    /// `flightdeck wait`'s default bound (§6.1): under the 10-minute tool timeout agents run
    /// with, so a `wait` returns 124 to the agent rather than being killed by its harness.
    static let defaultWaitTimeout: TimeInterval = 9 * 60
    /// The largest patch sent inline: a bigger JSON string on the control socket would stall
    /// every other reply behind it, so it goes to a file and the CLI gets the path.
    static let inlinePatchLimit = 1024 * 1024

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "delegation")

    let registry: RunRegistry
    private let deps: Dependencies
    /// Runs this app instance is watching, by local id.
    private var live: [String: LiveRun] = [:]
    /// Replay tasks (`logs`, `wait {from}`) still running: each ends with its run, its reader
    /// (the request's `ReplyCancellation`), or its own end, so a test can see none leak.
    private(set) var activeReplays = 0

    init(registry: RunRegistry, dependencies: Dependencies) {
        self.registry = registry
        self.deps = dependencies
        sweep()
        pruneExpired()
        resumeWatching()
    }

    /// What happened to a run, as the CLIs watching it need it.
    private enum Update {
        case notice(String)
        case output(RunOutputStream, offset: Int64, Data)
        /// The run ended: its CLI status, and the missing-file hint when one applies.
        case ended(status: Int32, hint: String?)
        /// The link to the host failed mid-run. The run itself carries on there.
        case lost(String)
    }

    private final class LiveRun {
        var link: any HostLinking
        var reservation: (any PortReservation)?
        var subscribers: [UUID: (Update) -> Void] = [:]
        /// The last `MissingFileHint.tailBytes` of stderr and pty output.
        var errorTail = Data()
        /// One past the last output byte seen: where a non-following `logs` stops.
        var outputEnd: Int64 = 0
        /// Watched by this app instance from the run's start, so `outputEnd` is the truth. A
        /// watcher restarted after a relaunch is still catching up, and `logs` must not trust it.
        let watchedFromStart: Bool
        var ended: (status: Int32, hint: String?)?
        var monitor: Task<Void, Never>?

        init(link: any HostLinking, watchedFromStart: Bool) {
            self.link = link
            self.watchedFromStart = watchedFromStart
        }

        func publish(_ update: Update) {
            for subscriber in subscribers.values { subscriber(update) }
        }
    }

    /// Watches again every run the registry still has going — after a relaunch, so services
    /// that die and runs that finish are recorded without anyone asking first. A host that is
    /// not connected yet is skipped; a later `wait`/`logs`, or `LiveHostDirectory.onHostOnline`
    /// calling this again once the link is up, picks it up.
    func resumeWatching() {
        for record in registry.runs where record.state == .running || record.state == .queued {
            _ = try? ensureLive(record)
        }
    }

    // MARK: Entry

    /// Answers one request. `reply` may be called several times for a streaming `cid`, always
    /// on the main actor, and the last call is the terminal frame.
    ///
    /// `cancellation` fires when the reader is gone — the stream's last frame went out, it was
    /// dropped as a `slow_reader`, or the connection ended — and stops whatever is still
    /// producing for this `cid`. Without it every resume left a replay running to the run's end.
    func handle(_ request: DelegateRequest, caller: ControlCaller, cid: Int,
                cancellation: ReplyCancellation? = nil, reply: @escaping (ServerFrame) -> Void) {
        let cancellation = cancellation ?? ReplyCancellation()
        let owner: UUID?
        switch caller {
        case .human: owner = nil
        case .session(let id): owner = id
        case .invalid:
            // A token that names no tab could own nothing it starts and see nothing it asks
            // about, so every answer would be wrong; refused like a scoped write is.
            return reply(.err(cid: cid, code: "out_of_scope",
                              message: "this tab's control token is not valid — reopen the tab and retry"))
        }
        Task { @MainActor in
            do {
                switch request {
                case .run(let run):
                    try await self.start(run, mode: .run, owner: owner, cid: cid, cancellation: cancellation, reply: reply)
                case .exec(let run):
                    try await self.start(run, mode: .exec, owner: owner, cid: cid, cancellation: cancellation, reply: reply)
                case .up(let run):
                    try await self.start(run, mode: .up, owner: owner, cid: cid, cancellation: cancellation, reply: reply)
                case .down(let service, _):
                    try await self.down(try self.service(service, owner: owner))
                    reply(.ack(cid: cid))
                case .restart(let service, _):
                    try await self.restart(try self.service(service, owner: owner), cid: cid, reply: reply)
                case .sync(let service, _):
                    try await self.sync(try self.service(service, owner: owner), cid: cid, reply: reply)
                case .ps:
                    let rows = self.registry.runs.filter { $0.isVisible(to: owner) }.map(\.row)
                    reply(.delegateRuns(cid: cid, rows))
                case .wait(let id, let timeout, let from, let noTimeout):
                    let seconds = noTimeout ? nil : timeout.map(TimeInterval.init) ?? Self.defaultWaitTimeout
                    try self.wait(try self.visibleRun(id, owner: owner), timeout: seconds, from: from,
                                  reattach: noTimeout, cid: cid, cancellation: cancellation, reply: reply)
                case .logs(let id, let follow, let from):
                    try self.logs(try self.visibleRun(id, owner: owner), follow: follow, from: from ?? 0,
                                  timeout: nil, endFromRun: false, hint: false, cid: cid,
                                  cancellation: cancellation, reply: reply)
                case .stop(let id):
                    let record = try self.visibleRun(id, owner: owner)
                    if record.kind == .service {
                        try await self.down(record)
                    } else {
                        _ = try await self.hostRequest(.runCancel(runID: record.hostRunID), on: try self.link(for: record))
                    }
                    reply(.ack(cid: cid))
                case .diff(let id):
                    reply(.delegatePatch(cid: cid, try await self.diff(try self.finishedRun(id, owner: owner))))
                case .apply(let id):
                    reply(.delegateApplied(cid: cid, try await self.apply(try self.finishedRun(id, owner: owner))))
                case .hostDisk(let host):
                    let link = try self.deps.hosts.link(named: host)
                    guard case .usage(let usage) = try await self.hostRequest(.workspaceUsage, on: link) else {
                        throw Self.unexpected(host, "workspace.usage")
                    }
                    reply(.hostDisk(cid: cid, usage.map {
                        WireWorkspaceUsage(repoRoot: $0.repoRoot, worktreeName: $0.worktreeName, bytes: $0.bytes)
                    }))
                case .hostPrune(let host, let repo):
                    _ = try await self.hostRequest(.workspacePrune(repoRoot: repo), on: try self.deps.hosts.link(named: host))
                    reply(.ack(cid: cid))
                case .recipeList(let cwd):
                    reply(.recipes(cid: cid, Self.book(try await self.config(cwd: cwd).config)))
                case .recipeAdd(let cwd, let name, let recipe):
                    let worktree = try await self.locate(cwd).worktree
                    try self.deps.config.add(try Self.recipe(recipe), named: name, worktree: worktree)
                    reply(.ack(cid: cid))
                case .recipeCheck(let cwd):
                    reply(.recipeCheck(cid: cid, problems: await self.check(cwd: cwd)))
                }
            } catch {
                reply(Self.refusal(cid: cid, error))
            }
        }
    }

    /// The tab closed: its services go `down` (§6.2), so nothing keeps a port forwarded or a
    /// database running for a session that no longer exists. Plain runs are left to finish.
    func sessionClosed(_ session: UUID) {
        let services = registry.runs.filter {
            $0.owner == session && $0.kind == .service && ($0.state == .running || $0.state == .queued)
        }
        for service in services {
            Task { @MainActor in
                do { try await self.down(service) } catch {
                    Self.logger.error("down \(service.id, privacy: .public) on tab close: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Retention

    /// Lets go of every run retention expires (`RunRegistry.expired`: finished over 14 days
    /// ago, or past the newest 500 finished on its host), and everything kept for it, in one
    /// place: its registry entry, its output copy, and its result bundle and other scratch
    /// files. Separately, each would leak the others: a bundle no registry entry names is
    /// never applied or deleted, and a copy no entry names is never read again.
    func pruneExpired(now: Date = Date()) {
        let expired = registry.expired(now: now)
        guard !expired.isEmpty else { return }
        deps.hosts.forget(expired)
        let files = expired.flatMap { run in
            scratchFiles(run.id) + (run.resultBundle.map { [URL(fileURLWithPath: $0)] } ?? [])
        }
        for run in expired { live[run.id] = nil }
        registry.remove(Set(expired.map(\.id)))
        Task.detached { for file in files { try? FileManager.default.removeItem(at: file) } }
    }

    /// The scratch files `directory` may hold for a run: everything is named for its local id.
    private func scratchFiles(_ id: String) -> [URL] {
        ["\(id).bundle", "\(id)-artifacts.tar", "\(id).patch"].map(scratchFile)
    }

    /// At launch: deletes what `directory` holds for no run in the registry. That is a run
    /// pruned while the app was not running to see it, an output copy under a name from before
    /// copies were keyed by local id (`<host slot>-<host run id>.out`, which a host that reused
    /// its ids could overwrite), and a provisional copy whose run never got its id. Listed
    /// now, deleted off the main actor: a file any run makes from here on is not in the list.
    private func sweep() {
        let known = Set(registry.runs.map(\.id))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: deps.directory.path)) ?? []
        let stale = names.filter { name in
            guard let match = name.wholeMatch(of: #/(r\d+)(\.out|\.out\.compact|\.bundle|-artifacts\.tar|\.patch)/#)
            else { return name.hasSuffix(".out") || name.hasSuffix(".out.compact") }
            return !known.contains(String(match.1))
        }.map { deps.directory.appendingPathComponent($0) }
        guard !stale.isEmpty else { return }
        Task.detached {
            RunMirror.waitForIO()
            for file in stale { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: run / exec / up

    private enum Mode { case run, exec, up }

    /// `owner` is the tab the new run belongs to — for `restart`/`sync`, the original
    /// service's, whoever asked.
    private func start(_ run: WireDelegateRun, mode: Mode, owner: UUID?, cid: Int,
                       cancellation: ReplyCancellation = ReplyCancellation(),
                       reply: @escaping (ServerFrame) -> Void) async throws {
        // §7 step 1: resolve the worktree, the recipe and the host — all local, all before
        // anything is reserved, so a typo costs nothing.
        let (worktree, subdir) = try await locate(run.cwd)
        let config = try loadConfig(worktree) ?? DelegateConfig()
        // `exec` never routes: it inspects the existing checkout with exactly the argv given.
        let routed = mode == .exec ? nil : RouteMatcher(config: config).match(run.command)?.recipe
        let recipeName = run.recipe ?? routed
        var recipe: Recipe?
        if let recipeName {
            guard let found = config.recipes[recipeName] else {
                throw DelegationError(code: "unknown_recipe",
                                      message: "no recipe named \(recipeName) in .flightdeck/delegate.toml — flightdeck recipe ls lists them")
            }
            recipe = found
        }
        let command = try Self.command(argv: run.command, recipe: recipe, routed: run.recipe == nil)
        let host = try resolveHost(run.host ?? recipe?.host ?? config.defaultHost)
        let service = mode == .up || recipe?.service == true
        let include = config.include + run.include
        let fetch = (recipe?.fetch ?? []) + run.fetch
        let spec = RunSpec(
            command: command, subdir: subdir,
            env: (recipe?.env ?? [:]).merging(run.env) { _, cli in cli },
            pty: run.pty, screen: run.screen || recipe?.screen == true, service: service,
            downCommand: recipe?.down, ports: try Preflight.mergePorts(recipe: recipe?.ports ?? [], cli: run.ports),
            ptySize: run.columns.flatMap { columns in run.rows.map { TerminalSize(columns: columns, rows: $0) } },
            // Only a service is kept alive past a lost controller, so only a service's counts.
            fetch: fetch, pool: recipe?.pool, orphanTimeout: service ? recipe?.orphanTimeout : nil)
        try await ensureCloudHost(host, config: config, worktree: worktree, cid: cid, reply: reply)
        let link = try deps.hosts.link(named: host)
        // Before anything streams, so a detached run (whose stream ends on `delegateStarted`)
        // still shows what the machine it lands on is costing.
        if let cost = deps.infra?.costLine(host: host) { reply(.delegateNotice(cid: cid, message: cost)) }

        // §7 steps 2–7. A preflight failure's message is already the finished §5 line, host
        // and next step included: passed through as is.
        let plan = DelegationPlan(host: host, worktree: worktree, subdir: subdir, spec: spec,
                                  include: include, fetch: fetch, sync: mode != .exec)
        let reservation = try await deps.preflight.preflight(plan, link: link)
        // Nothing after this point may leave the reservation held on failure.
        let hostRunID: String
        let snapshot: SnapshotRef
        do {
            // `exec` still takes a snapshot, for the workspace identity `run.start` needs
            // (repo root commit, worktree key): only the snapshotter computes those, and a
            // second derivation here could disagree with it and address another checkout.
            // The host ignores its commit and tree when `apply` is false.
            snapshot = try await deps.snapshots.snapshot(worktree: worktree, host: host, include: include)
            if mode != .exec { try await push(snapshot, from: worktree, to: link) }
            // The tab's display title: the host prints it to *another* tab's agent waiting on
            // the screen, so never a token or an internal id.
            let label = owner.flatMap(deps.sessionTitle) ?? "terminal"
            guard case .runStart(let id) = try await hostRequest(
                .runStart(ref: snapshot, spec: spec, owner: label, apply: mode != .exec), on: link)
            else { throw Self.unexpected(host, "run.start") }
            hostRunID = id
        } catch {
            reservation.release()
            throw Self.named(error, host: host)
        }

        let id = registry.mintID()
        var record = DelegatedRun(
            id: id, hostRunID: hostRunID, host: host, owner: owner, kind: service ? .service : .run,
            command: command, recipe: recipeName, state: .running, status: nil,
            ports: reservation.forwards.map { "\($0.local):\($0.remote)" },
            startedAt: Date(), worktree: worktree.path, snapshot: mode == .exec ? nil : snapshot,
            applyMode: recipe?.apply ?? .review, request: run, resultCommit: nil, resultBundle: nil)
        record.include = include
        record.fetch = fetch
        registry.add(record)
        let liveRun = LiveRun(link: link, watchedFromStart: true)
        live[id] = liveRun
        if service {
            liveRun.reservation = reservation
            reservation.startForwarding { remote in ServicePortOpener(link: link, service: hostRunID, remote: remote) }
        } else {
            reservation.release()
        }

        let started = WireDelegateStarted(runID: id, host: host, ports: reservation.forwards.map {
            WirePortBinding(local: $0.local, remote: $0.remote)
        })
        // Only the request decides (see the file header): the CLI read the recipe book and set
        // `detach` for a long or service recipe, and `up` is detached by definition.
        if mode == .up || run.detach {
            monitor(id, liveRun)
            return reply(.delegateStarted(cid: cid, started))
        }
        reply(.delegateStarted(cid: cid, started))
        attach(liveRun, cid: cid, hint: true, cancellation: cancellation, reply: reply)
        monitor(id, liveRun)
    }

    /// A run aimed at a `[infra.<name>]` machine that is not a paired host yet: created first
    /// when the recipe says `auto_up`, with its progress as notices; otherwise refused with the
    /// command that creates it, rather than the directory's bare "unknown host".
    private func ensureCloudHost(_ host: String, config: DelegateConfig, worktree: URL, cid: Int,
                                 reply: @escaping (ServerFrame) -> Void) async throws {
        guard let recipe = config.infra[host],
              !deps.hosts.hostNames.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) else { return }
        guard recipe.autoUp, let infra = deps.infra else {
            throw DelegationError(code: "unknown_host",
                                  message: "\(host) is a cloud machine that is not up — run `flightdeck infra up \(host)` first, or set auto_up = true in [infra.\(host)]")
        }
        let what: String
        switch recipe.source {
        case .preset(let preset): what = ([preset] + [recipe.instanceType].compactMap { $0 }).joined(separator: ", ")
        case .module(let path): what = "module \(path)"
        }
        reply(.delegateNotice(cid: cid, message: "creating \(host) (\(what))…"))
        try await infra.ensureUp(name: host, config: recipe, repoRoot: worktree) { line in
            reply(.delegateNotice(cid: cid, message: line))
        }
    }

    /// Streams a run's updates to one CLI until it ends, or the CLI is gone.
    private func attach(_ liveRun: LiveRun, cid: Int, hint: Bool, cancellation: ReplyCancellation,
                        reply: @escaping (ServerFrame) -> Void) {
        let token = UUID()
        cancellation.onCancel { [weak liveRun] in liveRun?.subscribers[token] = nil }
        liveRun.subscribers[token] = { [weak liveRun] update in
            switch update {
            case .notice(let message): reply(.delegateNotice(cid: cid, message: message))
            case .output(let stream, let offset, let data):
                reply(.delegateOutput(cid: cid, stream: stream.rawValue, offset: offset, data: data))
            case .ended(let status, let missing):
                liveRun?.subscribers[token] = nil
                if hint, let missing { return reply(.err(cid: cid, code: "missing_include", message: missing)) }
                reply(.delegateExit(cid: cid, status: status))
            case .lost(let message):
                liveRun?.subscribers[token] = nil
                reply(.err(cid: cid, code: "run_lost", message: message))
            }
        }
    }

    /// Watches a run to its end, whoever (if anyone) is attached: the registry's state, a
    /// result to fetch, artifacts, `apply = "auto"`, the missing-file hint.
    private func monitor(_ id: String, _ liveRun: LiveRun) {
        guard liveRun.monitor == nil, let record = registry.run(id) else { return }
        liveRun.monitor = Task { @MainActor [weak self] in
            do {
                for try await event in liveRun.link.events(runID: record.hostRunID, localID: record.id, from: 0) {
                    guard let self, liveRun.ended == nil else { return }
                    switch event {
                    case .queued(let position, let reason, let holder):
                        self.registry.update(id) { $0.state = .queued }
                        liveRun.publish(.notice(self.waiting(on: reason, position: position, holder: holder, host: record.host)))
                    case .started:
                        self.registry.update(id) { $0.state = .running }
                    case .output(let stream, let offset, let data):
                        liveRun.outputEnd = max(liveRun.outputEnd, offset + Int64(data.count))
                        if stream != .stdout {
                            liveRun.errorTail.append(data)
                            if liveRun.errorTail.count > MissingFileHint.tailBytes {
                                liveRun.errorTail = liveRun.errorTail.suffix(MissingFileHint.tailBytes)
                            }
                        }
                        liveRun.publish(.output(stream, offset: offset, data))
                    case .exited(let exit):
                        await self.finish(id, liveRun, exit: exit)
                        return
                    case .serviceDied(let exit):
                        liveRun.reservation?.release()
                        self.registry.update(id) { $0.state = .died; $0.status = exit.cliStatus }
                        self.end(liveRun, status: exit.cliStatus, hint: nil)
                        return
                    }
                }
            } catch let error as DelegationError where error.code == "unknown_run" {
                // The host no longer has the run: hostd restarted (its runs die with it) or
                // pruned it. Nothing will ever report its end, so it ends here, or every
                // `wait` on it would hang and `ps` would show it running forever.
                guard let self else { return }
                liveRun.reservation?.release()
                self.registry.update(id) { $0.state = .died; $0.status = 125 }
                liveRun.publish(.notice("\(record.host) restarted and \(id) is gone — rerun it"))
                self.end(liveRun, status: 125, hint: nil)
            } catch {
                // Cleared so the next `wait`/`logs` (`ensureLive`) starts watching again.
                Self.logger.error("lost \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                liveRun.monitor = nil
                liveRun.publish(.lost("lost the link to \(record.host) mid-run — \(id) carries on there; flightdeck logs \(id) --follow"))
            }
        }
    }

    private func finish(_ id: String, _ liveRun: LiveRun, exit: RunExit) async {
        liveRun.reservation?.release()
        guard let record = registry.run(id) else { return }
        let status = exit.cliStatus
        if record.kind == .run, let snapshot = record.snapshot {
            await fetchResult(record, snapshot: snapshot, liveRun)
            if !record.fetch.isEmpty { await fetchArtifacts(record, globs: record.fetch, liveRun) }
            if record.applyMode == .auto { await autoApply(id, liveRun) } else { await announceChanges(id, liveRun) }
        }
        // Only a synced run: `exec` sent nothing, so "wasn't sent" would be no clue at all.
        var hint: String?
        if status != 0, record.kind == .run, let snapshot = record.snapshot {
            let worktree = URL(fileURLWithPath: record.worktree)
            let worktrees = deps.worktrees
            hint = await MissingFileHint.hint(
                tail: String(decoding: liveRun.errorTail, as: UTF8.self), worktree: worktree,
                worktreeName: snapshot.worktreeName, subdir: Self.subdir(of: record),
                sent: record.include, ignored: { await worktrees.ignored($0, in: $1) })
                .map { "\(record.host): \($0)" }
        }
        registry.update(id) { $0.state = .exited; $0.status = status }
        end(liveRun, status: status, hint: hint)
        pruneExpired()
    }

    private static func subdir(of record: DelegatedRun) -> String {
        guard record.request.cwd.hasPrefix(record.worktree) else { return "" }
        return String(record.request.cwd.dropFirst(record.worktree.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Records the end once: a service `down` ends it at once, and the host's own `exited`
    /// that follows changes nothing.
    private func end(_ liveRun: LiveRun, status: Int32, hint: String?) {
        guard liveRun.ended == nil else { return }
        liveRun.ended = (status, hint)
        liveRun.publish(.ended(status: status, hint: hint))
    }

    // MARK: Results

    private func fetchResult(_ record: DelegatedRun, snapshot: SnapshotRef, _ liveRun: LiveRun) async {
        let file = scratchFile("\(record.id).bundle")
        do {
            let reply = try await pull(to: file, over: liveRun.link) {
                .runResult(runID: record.hostRunID, channel: $0)
            } expectsBytes: {
                if case .runResult(let commit?) = $0 { return !commit.isEmpty }
                return false
            }
            guard case .runResult(let commit?) = reply else { return }
            registry.update(record.id) { $0.resultCommit = commit; $0.resultBundle = file.path }
            // Only now may the host drop its copy (Ruling 24: the controller acks a result with
            // `run.ack` only once it is stored, so a result dropped after sending is not lost).
            // Until the bundle is on disk and in the registry, a cut transfer is fetched again. Best effort — a lost ack, or a
            // host too old to know the op, only leaves the copy to the host's 24 h expiry.
            _ = try? await hostRequest(.runAck(runID: record.hostRunID, repoRoot: snapshot.repoRoot), on: liveRun.link)
        } catch {
            liveRun.publish(.notice("couldn't fetch \(record.id)'s changed files from \(record.host) — \(Self.describe(error))"))
        }
    }

    private func fetchArtifacts(_ record: DelegatedRun, globs: [String], _ liveRun: LiveRun) async {
        let file = scratchFile("\(record.id)-artifacts.tar")
        do {
            let reply = try await pull(to: file, over: liveRun.link) {
                .runArtifacts(runID: record.hostRunID, globs: globs, channel: $0)
            } expectsBytes: {
                if case .runArtifacts(true) = $0 { return true }
                return false
            }
            guard case .runArtifacts(true) = reply else { return }
            try await deps.results.extractArtifacts(tar: file, into: URL(fileURLWithPath: record.worktree))
            try? FileManager.default.removeItem(at: file)
        } catch {
            liveRun.publish(.notice("couldn't fetch \(record.id)'s artifacts from \(record.host) — \(Self.describe(error))"))
        }
    }

    /// `apply = "auto"` (§4.5): applied on completion unless the merge would conflict, in
    /// which case nothing is written and the result is kept for review — and the CLI is told,
    /// so the agent does not assume its changes landed.
    private func autoApply(_ id: String, _ liveRun: LiveRun) async {
        guard let record = registry.run(id), let commit = record.resultCommit, let bundle = record.resultBundle,
              let snapshot = record.snapshot
        else { return }
        do {
            switch try await deps.results.apply(bundle: URL(fileURLWithPath: bundle), commit: commit, snapshot: snapshot,
                                                worktree: URL(fileURLWithPath: record.worktree), allowConflicts: false) {
            case .clean, .nothing:
                clearResult(id)
                liveRun.publish(.notice("applied \(id)'s changed files"))
            case .conflicts(let paths):
                liveRun.publish(.notice("\(id)'s changes conflict with your edits (\(paths.joined(separator: ", "))) — kept for review: flightdeck diff \(id), then flightdeck apply \(id)"))
            }
        } catch {
            liveRun.publish(.notice("couldn't apply \(id)'s changes (\(Self.describe(error))) — kept for review: flightdeck diff \(id)"))
        }
    }

    /// `apply = "review"` (the default): the changes wait for `diff`/`apply`, and nothing else
    /// would tell an agent there are any. A run that changed nothing, or whose diff cannot be
    /// read, says nothing.
    private func announceChanges(_ id: String, _ liveRun: LiveRun) async {
        guard let record = registry.run(id), let commit = record.resultCommit, let bundle = record.resultBundle,
              let snapshot = record.snapshot,
              let patch = try? await deps.results.patch(bundle: URL(fileURLWithPath: bundle), commit: commit,
                                                        snapshot: snapshot, worktree: URL(fileURLWithPath: record.worktree))
        else { return }
        let files = patch.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.count
        guard files > 0 else { return }
        liveRun.publish(.notice("\(id) changed \(files) file\(files == 1 ? "" : "s") — flightdeck diff \(id)"))
    }

    private func diff(_ record: DelegatedRun) async throws -> WireDelegatePatch {
        guard let commit = record.resultCommit, let bundle = record.resultBundle, let snapshot = record.snapshot else {
            return WireDelegatePatch(runID: record.id, patch: "")
        }
        let patch = try await deps.results.patch(bundle: URL(fileURLWithPath: bundle), commit: commit, snapshot: snapshot,
                                                 worktree: URL(fileURLWithPath: record.worktree))
        guard patch.utf8.count > Self.inlinePatchLimit else { return WireDelegatePatch(runID: record.id, patch: patch) }
        let file = scratchFile("\(record.id).patch")
        try FileManager.default.createDirectory(at: deps.directory, withIntermediateDirectories: true)
        try Data(patch.utf8).write(to: file, options: .atomic)
        return WireDelegatePatch(runID: record.id, patchPath: file.path)
    }

    /// Refused when there is nothing to apply — the run changed nothing, or it was applied
    /// already — so `apply` exiting 0 always means files changed.
    private func apply(_ record: DelegatedRun) async throws -> WireDelegateApplied {
        guard let commit = record.resultCommit, let bundle = record.resultBundle, let snapshot = record.snapshot else {
            throw DelegationError(code: "nothing_to_apply",
                                  message: "\(record.id) has no changes to apply — it changed no files, or they were applied already")
        }
        let outcome = try await deps.results.apply(bundle: URL(fileURLWithPath: bundle), commit: commit, snapshot: snapshot,
                                                   worktree: URL(fileURLWithPath: record.worktree), allowConflicts: true)
        // Applied either way: conflict markers are now in the worktree, and applying the same
        // patch a second time would only stack another set on top.
        clearResult(record.id)
        if case .conflicts(let paths) = outcome { return WireDelegateApplied(runID: record.id, conflicts: paths) }
        return WireDelegateApplied(runID: record.id, conflicts: [])
    }

    private func clearResult(_ id: String) {
        if let bundle = registry.run(id)?.resultBundle { try? FileManager.default.removeItem(atPath: bundle) }
        registry.update(id) { $0.resultCommit = nil; $0.resultBundle = nil }
    }

    // MARK: wait / logs

    /// `flightdeck wait` (§6.1): blocks until the run ends and answers its status, or gives up
    /// after `timeout` (`wait_timeout`, 124) while the run carries on; nil `timeout` waits as
    /// long as the run takes. With `from` it also streams the output from that byte on, so a
    /// CLI that lost the app sees nothing twice and misses nothing. `reattach` is a run's own
    /// CLI picking it back up: it gets the missing-file hint the attached run would have.
    private func wait(_ record: DelegatedRun, timeout: TimeInterval?, from: Int64?, reattach: Bool, cid: Int,
                      cancellation: ReplyCancellation, reply: @escaping (ServerFrame) -> Void) throws {
        if let from {
            return try logs(record, follow: true, from: from, timeout: timeout, endFromRun: true, hint: reattach,
                            cid: cid, cancellation: cancellation, reply: reply)
        }
        if let status = record.status, record.state == .exited || record.state == .died {
            return reply(.delegateExit(cid: cid, status: status))
        }
        let liveRun = try ensureLive(record)
        if let ended = liveRun.ended { return reply(.delegateExit(cid: cid, status: ended.status)) }
        let token = UUID()
        var answered = false
        cancellation.onCancel { [weak liveRun] in
            answered = true
            liveRun?.subscribers[token] = nil
        }
        liveRun.subscribers[token] = { [weak liveRun] update in
            switch update {
            case .notice(let message):
                // "waiting for mini's screen …" matters most to exactly this caller.
                reply(.delegateNotice(cid: cid, message: message))
            case .ended(let status, _):
                // The hint is the attached `run`'s to print, beside the output it explains; a
                // `wait` reports the status the agent asked for.
                answered = true
                liveRun?.subscribers[token] = nil
                reply(.delegateExit(cid: cid, status: status))
            case .lost(let message):
                answered = true
                liveRun?.subscribers[token] = nil
                reply(.err(cid: cid, code: "run_lost", message: message))
            case .output:
                break
            }
        }
        guard let timeout else { return }
        expire(after: timeout, record, cid: cid, cancellation: cancellation) {
            guard !answered else { return false }
            answered = true
            liveRun.subscribers[token] = nil
            return true
        } reply: { reply($0) }
    }

    /// Replays the run's output from byte `from` (`HostLinking.events`).
    ///
    /// - `follow`: carries on to the end, bounded by `timeout` when it is a `wait`.
    /// - `endFromRun`: the terminal `delegateExit` comes from the run's own end — after the
    ///   watcher has fetched the result, the artifacts and applied `apply = "auto"` — never
    ///   from the replay's `exited`, which can arrive first: a resumed `run` must not exit
    ///   before its changes are in the worktree, as the attached one never does.
    /// - Neither: stops at the output end seen when it began (`ack`). That end is exact for a
    ///   run this app watched from its start. For one it did not (a relaunch), the replay is
    ///   taken as caught up once it goes quiet: `replayIdle` after an event, with
    ///   `replayFirstEvent` allowed for the first.
    private func logs(_ record: DelegatedRun, follow: Bool, from: Int64, timeout: TimeInterval?,
                      endFromRun: Bool, hint: Bool, cid: Int, cancellation: ReplyCancellation,
                      reply: @escaping (ServerFrame) -> Void) throws {
        let liveRun = try ensureLive(record)
        let ended = record.state == .exited || record.state == .died || liveRun.ended != nil
        let knowsEnd = liveRun.watchedFromStart && !ended
        let stopAt = liveRun.outputEnd
        if !follow, knowsEnd, stopAt <= from { return reply(.ack(cid: cid)) }
        var done = false
        var replayDone = false
        var lastEvent = 0
        let token = UUID()
        var replay: Task<Void, Never>?
        let close: () -> Void = { [weak liveRun] in
            done = true
            replay?.cancel()
            liveRun?.subscribers[token] = nil
        }
        let finish: (ServerFrame) -> Void = { frame in
            guard !done else { return }
            close()
            reply(frame)
        }
        let endIfReady: () -> Void = { [weak liveRun] in
            guard replayDone, let end = liveRun?.ended else { return }
            if hint, let missing = end.hint { return finish(.err(cid: cid, code: "missing_include", message: missing)) }
            finish(.delegateExit(cid: cid, status: end.status))
        }
        if endFromRun {
            liveRun.subscribers[token] = { update in
                switch update {
                case .ended: endIfReady()
                case .lost(let message): finish(.err(cid: cid, code: "run_lost", message: message))
                case .notice(let message): if !done { reply(.delegateNotice(cid: cid, message: message)) }
                case .output: break
                }
            }
        }
        cancellation.onCancel { close() }
        activeReplays += 1
        replay = Task { @MainActor in
            defer { self.activeReplays -= 1 }
            do {
                for try await event in liveRun.link.events(runID: record.hostRunID, localID: record.id, from: from) {
                    guard !done else { return }
                    lastEvent += 1
                    switch event {
                    case .output(let stream, let offset, let data):
                        reply(.delegateOutput(cid: cid, stream: stream.rawValue, offset: offset, data: data))
                        if !follow, knowsEnd, offset + Int64(data.count) >= stopAt { return finish(.ack(cid: cid)) }
                    case .exited(let exit), .serviceDied(let exit):
                        replayDone = true
                        if endFromRun { return endIfReady() }
                        return finish(follow ? .delegateExit(cid: cid, status: exit.cliStatus) : .ack(cid: cid))
                    case .queued, .started:
                        break
                    }
                }
                guard !done else { return }
                replayDone = true
                if endFromRun { return endIfReady() }
                finish(.ack(cid: cid))
            } catch {
                finish(Self.refusal(cid: cid, Self.named(error, host: record.host)))
            }
        }
        // Two replays have no end of their own to wait for, so they end when it goes quiet: a
        // `logs` of a run this app did not watch, and a reattach to a run that had already
        // ended — whose replay may never send `exited` (no mirror after a relaunch, the host's
        // spool expired), while its end is already known here.
        let endsWhenQuiet = endFromRun && ended
        if (!follow && !knowsEnd && !ended) || endsWhenQuiet {
            let idle = deps.replayIdle
            let first = deps.replayFirstEvent
            Task { @MainActor in
                // The first event may take a host round trip; after it, the replay comes all
                // at once, so a quiet `idle` means it has caught up.
                let step = min(idle, 0.1)
                var waited: TimeInterval = 0
                while !done, lastEvent == 0, waited < first {
                    try? await Task.sleep(nanoseconds: UInt64(step * 1e9))
                    waited += step
                }
                var seen = -1
                while !done, seen != lastEvent {
                    seen = lastEvent
                    try? await Task.sleep(nanoseconds: UInt64(idle * 1e9))
                }
                guard endsWhenQuiet else { return finish(.ack(cid: cid)) }
                replayDone = true
                endIfReady()
            }
        }
        guard let timeout else { return }
        expire(after: timeout, record, cid: cid, cancellation: cancellation) {
            guard !done else { return false }
            close()
            return true
        } reply: { reply($0) }
    }

    /// After `seconds`, answers `wait_timeout` unless `claim` says the wait already ended. Only
    /// the wait gives up: the run carries on, and the agent can wait again.
    /// The timer ends with the reader too (`cancellation`), so a dropped `wait` leaves no
    /// 9-minute sleeper behind.
    private func expire(after seconds: TimeInterval, _ record: DelegatedRun, cid: Int, cancellation: ReplyCancellation,
                        claim: @escaping () -> Bool, reply: @escaping (ServerFrame) -> Void) {
        let timer = Task { @MainActor in
            try? await self.deps.sleep(seconds)
            guard !Task.isCancelled, claim() else { return }
            reply(.err(cid: cid, code: "wait_timeout",
                       message: "\(record.id) is still running on \(record.host) after \(Int(seconds))s — flightdeck wait \(record.id) again, or flightdeck logs \(record.id)"))
        }
        cancellation.onCancel { timer.cancel() }
    }

    /// The live watcher for `record`, starting one for a run this app instance did not start
    /// (one from before a relaunch) or restarting one that lost its link, so `wait` still
    /// learns how it ends.
    private func ensureLive(_ record: DelegatedRun) throws -> LiveRun {
        let liveRun = try live[record.id] ?? LiveRun(link: link(for: record), watchedFromStart: false)
        live[record.id] = liveRun
        if liveRun.ended == nil, record.state == .exited || record.state == .died {
            // Finished before this app instance existed: nothing will ever publish its end, so
            // it is seeded from the record, or a reattach would wait on it forever. No hint:
            // that was the attached run's to give, at the time.
            liveRun.ended = (record.status ?? 0, nil)
        }
        if liveRun.ended != nil { return liveRun }
        // A watcher that lost its link restarts on whatever link the directory has now.
        if liveRun.monitor == nil { liveRun.link = try link(for: record) }
        monitor(record.id, liveRun)
        return liveRun
    }

    // MARK: Services

    /// Stops a service, and ends it for everyone watching: its `wait` answers at once rather
    /// than hanging on an `exited` the host may word differently.
    private func down(_ record: DelegatedRun) async throws {
        do {
            _ = try await hostRequest(.serviceDown(service: record.hostRunID), on: try link(for: record))
        } catch let error as DelegationError where error.code == "unknown_run" {
            // The host has no such service any more (hostd restarted, and its services with
            // it): already down, which is all `down` asks for.
        }
        live[record.id]?.reservation?.release()
        registry.update(record.id) { $0.state = .exited; $0.status = $0.status ?? 0 }
        if let liveRun = live[record.id] { end(liveRun, status: 0, hint: nil) }
    }

    /// Down, then up again with the same request — as the same tab's service, whoever asked.
    private func restart(_ record: DelegatedRun, cid: Int, reply: @escaping (ServerFrame) -> Void) async throws {
        try await down(record)
        try await start(record.request, mode: .up, owner: record.owner, cid: cid, reply: reply)
    }

    /// `flightdeck sync <service>` (§6.2): re-applies the current snapshot to the service's
    /// pinned checkout and answers `ack`, or restarts it when its recipe says
    /// `restart_on_sync` and answers as `restart` does (`delegateStarted`, the new id).
    private func sync(_ record: DelegatedRun, cid: Int, reply: @escaping (ServerFrame) -> Void) async throws {
        let worktree = URL(fileURLWithPath: record.worktree)
        let config = try loadConfig(worktree)
        if let name = record.recipe, config?.recipes[name]?.restartOnSync == true {
            return try await restart(record, cid: cid, reply: reply)
        }
        let link = try link(for: record)
        do {
            let snapshot = try await deps.snapshots.snapshot(worktree: worktree, host: record.host, include: record.include)
            try await push(snapshot, from: worktree, to: link)
            _ = try await hostRequest(.serviceSync(service: record.hostRunID, ref: snapshot), on: link)
        } catch {
            throw Self.named(error, host: record.host)
        }
        reply(.ack(cid: cid))
    }

    // MARK: Recipes

    private func config(cwd: String) async throws -> (worktree: URL, config: DelegateConfig) {
        let worktree = try await locate(cwd).worktree
        return (worktree, try loadConfig(worktree) ?? DelegateConfig())
    }

    private func check(cwd: String) async -> [String] {
        do {
            let (_, config) = try await config(cwd: cwd)
            return deps.config.problems(in: config, hosts: deps.hosts.hostNames)
        } catch {
            return [Self.describe(error)]
        }
    }

    static func book(_ config: DelegateConfig) -> WireRecipeBook {
        WireRecipeBook(
            defaultHost: config.defaultHost, include: config.include,
            recipes: config.recipes.sorted { $0.key < $1.key }.map { name, r in
                WireRecipe(name: name, host: r.host, run: r.run, down: r.down, screen: r.screen, long: r.long,
                           service: r.service, restartOnSync: r.restartOnSync, fetch: r.fetch, ports: r.ports,
                           env: r.env, apply: r.apply.rawValue, pool: r.pool)
            },
            routes: config.routes.map { WireRoute(match: $0.match, recipe: $0.recipe) })
    }

    static func recipe(_ wire: WireRecipe) throws -> Recipe {
        guard let apply = ApplyMode(rawValue: wire.apply) else {
            throw DelegationError(code: "invalid_recipe", message: "apply must be review or auto, got \(wire.apply)")
        }
        _ = try Preflight.mergePorts(recipe: wire.ports, cli: [])
        return Recipe(host: wire.host, run: wire.run, down: wire.down, screen: wire.screen, long: wire.long,
                      service: wire.service, restartOnSync: wire.restartOnSync, fetch: wire.fetch,
                      ports: wire.ports, env: wire.env, apply: apply, pool: wire.pool)
    }

    // MARK: Resolution

    private func locate(_ cwd: String) async throws -> (worktree: URL, subdir: String) {
        do { return try await deps.worktrees.locate(cwd: URL(fileURLWithPath: cwd)) } catch {
            throw DelegationError(code: "not_a_repo", message: "\(cwd) is not in a git worktree — delegation syncs a git checkout; cd into one")
        }
    }

    private func loadConfig(_ worktree: URL) throws -> DelegateConfig? {
        do { return try deps.config.load(worktree: worktree) } catch {
            throw DelegationError(code: "invalid_config",
                                  message: ".flightdeck/delegate.toml: \(Self.describe(error)) — flightdeck recipe check")
        }
    }

    /// §5: `--on`, then the recipe's host, then the route's recipe's (the same lookup), then
    /// `default_host`; with none, a failure that lists what is paired.
    private func resolveHost(_ name: String?) throws -> String {
        if let name { return name }
        let paired = deps.hosts.hostNames
        guard !paired.isEmpty else {
            throw DelegationError(code: "no_host", message: "no hosts are paired — pair one in Settings › Hosts, then rerun with --on <host>")
        }
        throw DelegationError(code: "no_host",
                              message: "no host given and no default_host in .flightdeck/delegate.toml — rerun with --on \(paired.joined(separator: "|"))")
    }

    /// The run's link: the one it is watched on while that is up, else a fresh one from the
    /// directory — a link that dropped is never reused, so the first request after a host
    /// comes back does not fail on the corpse of the old one.
    private func link(for record: DelegatedRun) throws -> any HostLinking {
        if let liveRun = live[record.id], liveRun.link.isConnected { return liveRun.link }
        let link = try deps.hosts.link(named: record.host)
        live[record.id]?.link = link
        return link
    }

    /// A run or service named by id, which must be the caller's own: another tab's run is
    /// `not_found` rather than "not yours", so one agent cannot even probe another's ids.
    private func visibleRun(_ id: String, owner: UUID?) throws -> DelegatedRun {
        guard let record = registry.run(id), record.isVisible(to: owner) else {
            throw DelegationError(code: "not_found", message: "no run \(id) in this session — flightdeck ps lists them")
        }
        return record
    }

    private func finishedRun(_ id: String, owner: UUID?) throws -> DelegatedRun {
        let record = try visibleRun(id, owner: owner)
        guard record.state == .exited || record.state == .died else {
            throw DelegationError(code: "still_running", message: "\(id) is still running on \(record.host) — flightdeck wait \(id) first")
        }
        return record
    }

    /// A running service by run id, or by recipe name (the most recent one this caller owns).
    private func service(_ name: String, owner: UUID?) throws -> DelegatedRun {
        let candidates = registry.runs.filter {
            $0.kind == .service && $0.isVisible(to: owner) && ($0.state == .running || $0.state == .queued)
        }
        if let byID = candidates.first(where: { $0.id == name }) { return byID }
        if let byRecipe = candidates.last(where: { $0.recipe == name }) { return byRecipe }
        throw DelegationError(code: "not_found", message: "no running service \(name) in this session — flightdeck ps lists them")
    }

    /// The shell text to run. A recipe's `run`, with any extra argv appended; a routed
    /// command, which is the argv itself (the route only picked the recipe's settings); or a
    /// plain `-- cmd…`.
    ///
    /// A single argument is passed through as shell text, so `-- 'make && make test'` works as
    /// it would over ssh; several are quoted word by word, so `-- xcodebuild -scheme "My App"`
    /// reaches the host as the three words it was.
    static func command(argv: [String], recipe: Recipe?, routed: Bool) throws -> String {
        if let recipe, !routed || argv.isEmpty {
            return ([recipe.run] + argv.map(shellQuote)).joined(separator: " ")
        }
        guard !argv.isEmpty else {
            throw DelegationError(code: "no_command", message: "nothing to run — name a recipe, or give the command after --")
        }
        return argv.count == 1 ? argv[0] : argv.map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%_+=:,./-"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Transfer

    private func push(_ snapshot: SnapshotRef, from worktree: URL, to link: any HostLinking) async throws {
        guard case .syncTips(let tips) = try await hostRequest(.syncTips(repoRoot: snapshot.repoRoot, wtKey: snapshot.wtKey), on: link)
        else { throw Self.unexpected(link.name, "sync.tips") }
        let bundle = try await deps.bundles.bundle(worktree: worktree, snapshot: snapshot, haves: tips)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let channel = try await link.openChannel()
        async let pushed = hostRequest(.syncPush(ref: snapshot, channel: channel.id), on: link)
        do {
            try await Self.send(bundle, over: channel)
        } catch {
            channel.cancel()
            _ = try? await pushed
            throw error
        }
        _ = try await pushed
    }

    /// The bundle's bytes onto the channel, read off the main actor.
    private nonisolated static func send(_ file: URL, over channel: any ByteChannel) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try await channel.write(chunk)
        }
        await channel.finish()
    }

    /// Sends `request` naming a fresh channel and saves what arrives on it to `file`. Read and
    /// asked at once: a host that streams before replying would otherwise stall on credit
    /// against a reader that is still waiting for the reply.
    private func pull(to file: URL, over link: any HostLinking,
                      request: (ChannelID) -> DelegationRequest,
                      expectsBytes: (DelegationReply) -> Bool) async throws -> DelegationReply {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let channel = try await link.openChannel()
        async let received: Void = Self.drain(channel, into: file)
        let reply: DelegationReply
        do {
            reply = try await hostRequest(request(channel.id), on: link)
        } catch {
            channel.cancel()
            _ = try? await received
            throw error
        }
        guard expectsBytes(reply) else {
            channel.cancel()
            _ = try? await received
            return reply
        }
        try await received
        return reply
    }

    private nonisolated static func drain(_ channel: any ByteChannel, into file: URL) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        while let chunk = try await channel.read() { try handle.write(contentsOf: chunk) }
        // Our half closed too, so the channel retires on both ends: a half-open one stays in
        // the mux's table for the life of the link, one per fetched result.
        await channel.finish()
    }

    private func scratchFile(_ name: String) -> URL { deps.directory.appendingPathComponent(name) }

    /// The §6.3 queue line: who holds the screen, by this Mac's run id when the holder is one
    /// of ours, or the checkout pool being full.
    private func waiting(on reason: WaitReason, position: Int, holder: LeaseHolder?, host: String) -> String {
        switch reason {
        case .slot:
            return "waiting for a free checkout on \(host)"
        case .screen:
            guard let holder else { return "waiting for \(host)'s screen (position \(position))" }
            // The newest live run under that host id: a host from before unique run ids (Ruling
            // 27) reused them across restarts, and only a run still going can hold the screen.
            let ours = registry.runs.last {
                $0.host == host && $0.hostRunID == holder.runID && !$0.state.isFinished
            }?.id
            return "waiting for \(host)'s screen — held by \(ours ?? holder.runID) (session \"\(holder.session)\")"
        }
    }

    /// Every host request goes through here, so a host's `err` becomes its §5 line, naming the
    /// host and what to do, at one place.
    private func hostRequest(_ request: DelegationRequest, on link: any HostLinking) async throws -> DelegationReply {
        do { return try await link.request(request) } catch HostLinkError.remote(let code, let message) {
            throw DelegationError(code: code, message: Self.hostLine(code: code, message: message, host: link.name))
        }
    }

    private static func unexpected(_ host: String, _ op: String) -> DelegationError {
        DelegationError(code: "unexpected_reply", message: "\(host) answered \(op) with something else — update Flight Deck on both machines")
    }

    /// The §5 line for each host error code pinned in `DelegationWire.swift`'s header (A5).
    static func hostLine(code: String, message: String, host: String) -> String {
        switch code {
        case "tree_mismatch": return "\(host): sync rejected: tree hash mismatch — rerun; if it repeats, flightdeck host prune \(host)"
        case "lfs_unsupported": return "\(host): LFS repos are not supported for delegation yet — run it locally"
        case "submodules_unsupported": return "\(host): submodules are not supported for delegation yet — run it locally"
        case "screen_locked": return "\(host)'s screen is locked — unlock it, then rerun"
        case "no_console_user": return "nobody is logged in at \(host)'s console — log in there, then rerun"
        case "screen_unsupported": return "\(host) has no screen for --screen runs — use a macOS host"
        case "no_checkout": return "\(host) has no checkout of this worktree yet — flightdeck run once to sync it, then exec"
        case "unknown_run": return "\(host) has no such run — flightdeck ps lists this session's runs"
        case "run_active": return "\(host): the run is still going — flightdeck wait it first"
        case "port_held": return "\(host): \(message) — free the port on \(host), or forward another with --port L:R"
        case "dial_failed": return "\(host): \(message) — is the service listening on that port?"
        case "result_expired": return "the result expired on \(host) — rerun to get the changes again"
        case "unsafe_path": return "\(host) sent back a result with an unsafe path, so nothing was applied — check the run's changes on \(host)"
        case "git_too_old": return "\(host)'s git is older than 2.40 — update git on \(host), then rerun"
        case "unsupported", "not_implemented": return "\(host) does not support this yet — update Flight Deck on \(host)"
        default: return "\(host): \(message)"
        }
    }

    // MARK: Errors

    /// The `err` frame for a failure. A `DelegationError`'s `message`, never its `description`,
    /// which already starts `flightdeck: ` — the CLI adds that itself.
    static func refusal(cid: Int, _ error: Error) -> ServerFrame {
        if let failure = error as? DelegationError {
            return .err(cid: cid, code: failure.code, message: failure.message)
        }
        return .err(cid: cid, code: "delegation_failed", message: describe(error))
    }

    /// Names the host in a failure that is not already a finished line. Every `DelegationError`
    /// here is one — `hostLine`, the preflight and the directory all word their own — so only
    /// a stray error is wrapped.
    private static func named(_ error: Error, host: String) -> Error {
        if error is DelegationError { return error }
        return DelegationError(code: "delegation_failed", message: "\(host): \(describe(error))")
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? DelegationError { return failure.message }
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }
}
