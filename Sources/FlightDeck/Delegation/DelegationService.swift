import FleetKit
import Foundation
import HostKit
import os

// The app half of delegated execution (spec §4–§7): what `flightdeck run`, `up`, `wait`, …
// ask of the control socket, carried out against a paired host.
//
// Every piece that touches git, a socket or a host is behind one of the protocols below, so
// the whole flow — resolve, preflight, sync, start, stream, result — runs in a unit test
// against in-memory fakes. Track C8 plugs in the real ones: `HostLink` + the channel mux for
// `HostLinking`, C2's `Snapshotter`/`BundleMaker`/`ResultApplier`, C5's preflight and port
// forwarder, C4's TOML parser and route matcher.
//
// Streaming (DelegationControlWire.swift's "Streams"): a `run` answers its `cid` with
// `delegateStarted`, any `delegateNotice`s and `delegateOutput`s, and ends it with exactly one
// terminal frame:
//   delegateStarted         when detached (`--detach`, a `long` recipe, every service): the
//                           CLI prints the id and exits 0; this service sends nothing after it
//   delegateExit {status}   an attached run ended; the CLI exits with `status`
//   err {code, message}     delegation failed (125), the missing-file hint (125), or a
//                           `wait` timeout (`wait_timeout`, 124)

// MARK: - Seams

/// A paired, connected host, as delegation drives it. C8's adapter wraps `HostLink` and the
/// channel mux. A host's `err` reaches here as `HostLinkError.remote(code:message:)`, whose
/// codes `DelegationService.hostLine` turns into the §5 lines.
@MainActor
protocol HostLinking: AnyObject {
    /// The registry name, for every message that names the host.
    var name: String { get }
    /// One request, answered by its reply; a host error throws (`HostLinkError.remote`).
    func request(_ request: DelegationRequest) async throws -> DelegationReply
    /// A fresh channel whose id a following request names (`sync.push`, `run.result`, …).
    func openChannel() async throws -> any ByteChannel
    /// Every event for `runID` from output byte `offset` on, then live ones until it exits.
    /// The adapter must buffer events that arrive before anyone subscribes — a `run.start`
    /// attaches at once, so its first output can beat the reply naming the run — and re-send
    /// `run.attach` from the last delivered offset after a reconnect, so a laptop that slept
    /// mid-run loses nothing and repeats nothing.
    func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error>
}

/// The paired hosts, by name.
@MainActor
protocol DelegationHostDirectory: AnyObject {
    /// Every paired host, for the message that lists them when no host was given.
    var hostNames: [String] { get }
    /// The link to `name`. Throws `DelegationFailure` with the §5 line when it is unknown or
    /// offline ("mini is offline (last seen 4m ago)").
    func link(named name: String) throws -> any HostLinking
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

/// §7 steps 2–7, in order (C5's `Preflight`). Throws `DelegationFailure` with the 125 line;
/// a failure must leave nothing reserved.
protocol Preflighting {
    func preflight(_ plan: DelegationPlan, link: any HostLinking) async throws -> any _PendingPortReservation
}

/// What a passed preflight holds: the bound local listeners for a service's ports (§7 step 4).
/// A stand-in for HostKit's `PortReservation` (track C5's `Preflight.swift`), which replaces it
/// when C5 merges: `forward(service:link:)` becomes its `startForwarding`. `release()` must
/// never block, since it is called on the main actor.
protocol _PendingPortReservation: AnyObject {
    /// The forwards as bound, `auto` resolved to the port actually chosen.
    var ports: [WirePortBinding] { get }
    /// Starts handing accepted connections to the host as `port.open` channels.
    func forward(service runID: String, link: any HostLinking)
    /// Idempotent: the preflight's failure path, `down`, and a service dying all call it.
    func release()
}

/// How a run's changed files came back, or did not.
enum ApplyOutcome: Equatable {
    case clean
    /// The paths left with conflict markers — or, when conflicts were not allowed, the paths
    /// that would have been, with nothing written.
    case conflicts([String])
    case nothing
}

/// The controller side of §4.5 (C2's `ResultApplier`).
protocol ResultApplying {
    /// `git diff` text for `commit` against `snapshot`.
    func patch(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL) throws -> String
    /// A three-way merge into the **current** worktree with `snapshot` as the base, so edits
    /// made during the run conflict rather than being overwritten. `allowConflicts: false` is
    /// `apply = "auto"`: a conflicting merge writes nothing and reports the paths.
    func apply(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL,
               allowConflicts: Bool) throws -> ApplyOutcome
    /// Unpacks the artifact tar into the worktree; a file replaces a local one only if ignored.
    func extractArtifacts(tar: URL, into worktree: URL) throws
}

/// `.flightdeck/delegate.toml` (C4's parser and writer behind it).
protocol DelegateConfigLoading {
    /// Nil when the project has no `delegate.toml`, which is not an error: `run --on mini --
    /// make` needs none.
    func load(worktree: URL) throws -> DelegateConfig?
    func add(_ recipe: Recipe, named name: String, worktree: URL) throws
    /// `recipe check`'s findings; empty means valid.
    func problems(in config: DelegateConfig, hosts: [String]) -> [String]
    /// The recipe of the first `[[route]]` whose glob matches the joined argv.
    func recipe(routing argv: [String], in config: DelegateConfig) -> String?
}

/// Finds the worktree a CLI's cwd is in, and asks git about it.
protocol WorktreeLocating {
    /// The worktree root, and the cwd relative to it ("" at the root).
    func locate(cwd: URL) throws -> (worktree: URL, subdir: String)
    /// Which of `paths` (worktree-relative) git ignores.
    func ignored(_ paths: [String], in worktree: URL) -> Set<String>
}

/// A delegation that could not go ahead. `message` is the one line the CLI prints after
/// `flightdeck: ` before exiting 125, so it names the host and the next step.
struct DelegationFailure: Error, Equatable {
    let code: String
    let message: String
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
    /// Runs this app instance is watching, by local id. A run from before a relaunch has none
    /// until something asks about it (`ensureLive`).
    private var live: [String: LiveRun] = [:]

    init(registry: RunRegistry, dependencies: Dependencies) {
        self.registry = registry
        self.deps = dependencies
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
        let link: any HostLinking
        var reservation: (any _PendingPortReservation)?
        var subscribers: [UUID: (Update) -> Void] = [:]
        /// The last `MissingFileHint.tailBytes` of stderr and pty output.
        var errorTail = Data()
        /// One past the last output byte seen: where a non-following `logs` stops.
        var outputEnd: Int64 = 0
        var ended: (status: Int32, hint: String?)?
        var monitor: Task<Void, Never>?

        init(link: any HostLinking) { self.link = link }

        func publish(_ update: Update) {
            for subscriber in subscribers.values { subscriber(update) }
        }
    }

    // MARK: Entry

    /// Answers one request. `reply` may be called several times for a streaming `cid`, always
    /// on the main actor, and the last call is the terminal frame.
    func handle(_ request: DelegateRequest, caller: ControlCaller, cid: Int,
                reply: @escaping (ServerFrame) -> Void) {
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
        let fail: (Error) -> Void = { reply(Self.refusal(cid: cid, $0)) }
        Task { @MainActor in
            do {
                switch request {
                case .run(let run): try await self.start(run, mode: .run, owner: owner, cid: cid, reply: reply)
                case .exec(let run): try await self.start(run, mode: .exec, owner: owner, cid: cid, reply: reply)
                case .up(let run): try await self.start(run, mode: .up, owner: owner, cid: cid, reply: reply)
                case .down(let service, _):
                    try await self.down(try self.service(service, owner: owner))
                    reply(.ack(cid: cid))
                case .restart(let service, _):
                    let record = try self.service(service, owner: owner)
                    try await self.down(record)
                    try await self.start(record.request, mode: .up, owner: owner, cid: cid, reply: reply)
                case .sync(let service, _):
                    try await self.sync(try self.service(service, owner: owner), owner: owner, cid: cid, reply: reply)
                case .ps:
                    let rows = self.registry.runs.filter { $0.isVisible(to: owner) }.map(\.row)
                    reply(.delegateRuns(cid: cid, rows))
                case .wait(let id, let timeout, let from):
                    try self.wait(try self.visibleRun(id, owner: owner), timeout: timeout, from: from, cid: cid, reply: reply)
                case .logs(let id, let follow, let from):
                    try self.logs(try self.visibleRun(id, owner: owner), follow: follow, from: from ?? 0,
                                  timeout: nil, cid: cid, reply: reply)
                case .stop(let id):
                    let record = try self.visibleRun(id, owner: owner)
                    if record.kind == .service {
                        try await self.down(record)
                    } else {
                        _ = try await self.hostRequest(.runCancel(runID: record.hostRunID), on: try self.link(for: record))
                    }
                    reply(.ack(cid: cid))
                case .diff(let id):
                    reply(.delegatePatch(cid: cid, try self.diff(try self.finishedRun(id, owner: owner))))
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
                case .apply(let id):
                    reply(.delegateApplied(cid: cid, try self.apply(try self.finishedRun(id, owner: owner))))
                case .recipeList(let cwd):
                    reply(.recipes(cid: cid, Self.book(try self.config(cwd: cwd).config)))
                case .recipeAdd(let cwd, let name, let recipe):
                    let worktree = try self.locate(cwd).worktree
                    try self.deps.config.add(try Self.recipe(recipe), named: name, worktree: worktree)
                    reply(.ack(cid: cid))
                case .recipeCheck(let cwd):
                    reply(.recipeCheck(cid: cid, problems: self.check(cwd: cwd)))
                }
            } catch {
                fail(error)
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

    // MARK: run / exec / up

    private enum Mode { case run, exec, up }

    private func start(_ run: WireDelegateRun, mode: Mode, owner: UUID?, cid: Int,
                       reply: @escaping (ServerFrame) -> Void) async throws {
        // §7 step 1: resolve the worktree, the recipe and the host — all local, all before
        // anything is reserved, so a typo costs nothing.
        let (worktree, subdir) = try locate(run.cwd)
        let config = try loadConfig(worktree) ?? DelegateConfig()
        let recipeName = run.recipe ?? deps.config.recipe(routing: run.command, in: config)
        var recipe: Recipe?
        if let recipeName {
            guard let found = config.recipes[recipeName] else {
                throw DelegationFailure(code: "unknown_recipe",
                                        message: "no recipe named \(recipeName) in .flightdeck/delegate.toml — flightdeck recipe ls lists them")
            }
            recipe = found
        }
        let command = try Self.command(argv: run.command, recipe: recipe, routed: run.recipe == nil)
        let host = try resolveHost(run.host ?? recipe?.host ?? config.defaultHost)
        let service = mode == .up || recipe?.service == true
        let spec = RunSpec(
            command: command, subdir: subdir,
            env: (recipe?.env ?? [:]).merging(run.env) { _, cli in cli },
            pty: run.pty, screen: run.screen || recipe?.screen == true, service: service,
            downCommand: recipe?.down, ports: try Self.ports(recipe: recipe?.ports ?? [], cli: run.ports),
            ptySize: run.columns.flatMap { columns in run.rows.map { TerminalSize(columns: columns, rows: $0) } },
            fetch: (recipe?.fetch ?? []) + run.fetch, pool: recipe?.pool)
        let include = config.include + run.include
        let fetch = (recipe?.fetch ?? []) + run.fetch
        let link = try deps.hosts.link(named: host)

        // §7 steps 2–7. Nothing after this point may leave the reservation held on failure.
        let plan = DelegationPlan(host: host, worktree: worktree, subdir: subdir, spec: spec,
                                  include: include, fetch: fetch, sync: mode != .exec)
        // A preflight failure's message is already the finished §5 line, host and next step
        // included: passed through as is, never re-prefixed.
        let reservation = try await deps.preflight.preflight(plan, link: link)
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
        let record = DelegatedRun(
            id: id, hostRunID: hostRunID, host: host, owner: owner, kind: service ? .service : .run,
            command: command, recipe: recipeName, state: .running, status: nil,
            ports: reservation.ports.map { "\($0.local):\($0.remote)" },
            startedAt: Date(), worktree: worktree.path, snapshot: mode == .exec ? nil : snapshot,
            applyMode: recipe?.apply ?? .review, request: run, resultCommit: nil, resultBundle: nil)
        registry.add(record)
        let liveRun = LiveRun(link: link)
        liveRun.reservation = reservation
        live[id] = liveRun
        if service { reservation.forward(service: hostRunID, link: link) } else { reservation.release() }

        let started = WireDelegateStarted(runID: id, host: host, ports: reservation.ports)
        if service || run.detach || recipe?.long == true {
            // Detached: `delegateStarted` is the terminal frame, and the CLI prints the id and
            // `flightdeck wait` and returns inside the agent's tool timeout. The monitor still
            // records how it ends, for that `wait`.
            monitor(id, liveRun, fetch: fetch, include: include)
            return reply(.delegateStarted(cid: cid, started))
        }
        reply(.delegateStarted(cid: cid, started))
        let token = UUID()
        liveRun.subscribers[token] = { [weak liveRun] update in
            switch update {
            case .notice(let message): reply(.delegateNotice(cid: cid, message: message))
            case .output(let stream, let offset, let data):
                reply(.delegateOutput(cid: cid, stream: stream.rawValue, offset: offset, data: data))
            case .ended(let status, let hint):
                liveRun?.subscribers[token] = nil
                if let hint { return reply(.err(cid: cid, code: "missing_include", message: hint)) }
                reply(.delegateExit(cid: cid, status: status))
            case .lost(let message):
                liveRun?.subscribers[token] = nil
                reply(.err(cid: cid, code: "run_lost", message: message))
            }
        }
        monitor(id, liveRun, fetch: fetch, include: include)
    }

    /// Watches a run to its end, whoever (if anyone) is attached: the registry's state, a
    /// result to fetch, artifacts, `apply = "auto"`, the missing-file hint.
    private func monitor(_ id: String, _ liveRun: LiveRun, fetch: [String], include: [String]) {
        guard liveRun.monitor == nil, let record = registry.run(id) else { return }
        liveRun.monitor = Task { @MainActor [weak self] in
            do {
                for try await event in liveRun.link.events(runID: record.hostRunID, from: 0) {
                    guard let self else { return }
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
                        await self.finish(id, liveRun, exit: exit, fetch: fetch, include: include)
                        return
                    case .serviceDied(let exit):
                        liveRun.reservation?.release()
                        self.registry.update(id) { $0.state = .died; $0.status = exit.cliStatus }
                        self.end(liveRun, status: exit.cliStatus, hint: nil)
                        return
                    }
                }
            } catch {
                // Cleared so the next `wait`/`logs` (`ensureLive`) starts watching again.
                Self.logger.error("lost \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                liveRun.monitor = nil
                liveRun.publish(.lost("lost the link to \(record.host) mid-run; \(id) carries on there — flightdeck logs \(id) --follow"))
            }
        }
    }

    private func finish(_ id: String, _ liveRun: LiveRun, exit: RunExit, fetch: [String], include: [String]) async {
        liveRun.reservation?.release()
        guard let record = registry.run(id) else { return }
        let status = exit.cliStatus
        let worktree = URL(fileURLWithPath: record.worktree)
        if record.kind == .run, let snapshot = record.snapshot {
            await fetchResult(record, snapshot: snapshot, liveRun)
            if !fetch.isEmpty { await fetchArtifacts(record, globs: fetch, liveRun) }
            if record.applyMode == .auto { autoApply(id, liveRun) }
        }
        var hint: String?
        if status != 0, record.kind == .run {
            hint = MissingFileHint.hint(
                tail: String(decoding: liveRun.errorTail, as: UTF8.self), worktree: worktree,
                worktreeName: record.snapshot?.worktreeName ?? worktree.lastPathComponent,
                subdir: record.request.cwd.hasPrefix(record.worktree)
                    ? String(record.request.cwd.dropFirst(record.worktree.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : "",
                sent: Set(include), ignored: { self.deps.worktrees.ignored($0, in: $1) })
                .map { "\(record.host): \($0)" }
        }
        registry.update(id) { $0.state = .exited; $0.status = status }
        end(liveRun, status: status, hint: hint)
    }

    private func end(_ liveRun: LiveRun, status: Int32, hint: String?) {
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
        } catch {
            liveRun.publish(.notice("couldn't fetch \(record.id)'s changed files from \(record.host): \(Self.describe(error))"))
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
            try deps.results.extractArtifacts(tar: file, into: URL(fileURLWithPath: record.worktree))
            try? FileManager.default.removeItem(at: file)
        } catch {
            liveRun.publish(.notice("couldn't fetch \(record.id)'s artifacts from \(record.host): \(Self.describe(error))"))
        }
    }

    /// `apply = "auto"` (§4.5): applied on completion unless the merge would conflict, in
    /// which case nothing is written and the result is kept for review — and the CLI is told,
    /// so the agent does not assume its changes landed.
    private func autoApply(_ id: String, _ liveRun: LiveRun) {
        guard let record = registry.run(id), let commit = record.resultCommit, let bundle = record.resultBundle,
              let snapshot = record.snapshot
        else { return }
        do {
            switch try deps.results.apply(bundle: URL(fileURLWithPath: bundle), commit: commit, snapshot: snapshot,
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

    private func diff(_ record: DelegatedRun) throws -> WireDelegatePatch {
        guard let commit = record.resultCommit, let bundle = record.resultBundle, let snapshot = record.snapshot else {
            return WireDelegatePatch(runID: record.id, patch: "")
        }
        let patch = try deps.results.patch(bundle: URL(fileURLWithPath: bundle), commit: commit, snapshot: snapshot,
                                           worktree: URL(fileURLWithPath: record.worktree))
        guard patch.utf8.count > Self.inlinePatchLimit else { return WireDelegatePatch(runID: record.id, patch: patch) }
        let file = scratchFile("\(record.id).patch")
        try FileManager.default.createDirectory(at: deps.directory, withIntermediateDirectories: true)
        try Data(patch.utf8).write(to: file, options: .atomic)
        return WireDelegatePatch(runID: record.id, patchPath: file.path)
    }

    private func apply(_ record: DelegatedRun) throws -> WireDelegateApplied {
        guard let commit = record.resultCommit, let bundle = record.resultBundle, let snapshot = record.snapshot else {
            return WireDelegateApplied(runID: record.id, conflicts: [])
        }
        let outcome = try deps.results.apply(bundle: URL(fileURLWithPath: bundle), commit: commit, snapshot: snapshot,
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
    /// after `timeout` (`wait_timeout`, 124) while the run carries on. With `from` it is a
    /// reattach — the CLI lost the app mid-run — and streams the output from that byte on, so
    /// the agent sees nothing twice and misses nothing.
    private func wait(_ record: DelegatedRun, timeout: Int?, from: Int64?, cid: Int,
                      reply: @escaping (ServerFrame) -> Void) throws {
        let seconds = timeout.map(TimeInterval.init) ?? Self.defaultWaitTimeout
        if let from { return try logs(record, follow: true, from: from, timeout: seconds, cid: cid, reply: reply) }
        if let status = record.status, record.state == .exited || record.state == .died {
            return reply(.delegateExit(cid: cid, status: status))
        }
        let liveRun = try ensureLive(record)
        if let ended = liveRun.ended { return reply(.delegateExit(cid: cid, status: ended.status)) }
        let token = UUID()
        var answered = false
        liveRun.subscribers[token] = { [weak liveRun] update in
            switch update {
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
            case .notice, .output:
                break
            }
        }
        expire(after: seconds, record, cid: cid) {
            guard !answered else { return false }
            answered = true
            liveRun.subscribers[token] = nil
            return true
        } reply: { reply($0) }
    }

    /// Replays the run's spooled output from the host, from byte `from`. Without `follow`, stops
    /// at what had been written when asked (`ack`); with it, carries on to the end
    /// (`delegateExit`), bounded by `timeout` when it is a `wait`.
    private func logs(_ record: DelegatedRun, follow: Bool, from: Int64, timeout: TimeInterval?, cid: Int,
                      reply: @escaping (ServerFrame) -> Void) throws {
        let liveRun = try ensureLive(record)
        let ended = record.state == .exited || record.state == .died || liveRun.ended != nil
        let stopAt = liveRun.outputEnd
        if !follow, !ended, stopAt <= from { return reply(.ack(cid: cid)) }
        var done = false
        let finish: (ServerFrame) -> Void = { frame in
            guard !done else { return }
            done = true
            reply(frame)
        }
        let replay = Task { @MainActor in
            do {
                for try await event in liveRun.link.events(runID: record.hostRunID, from: from) {
                    guard !done else { return }
                    switch event {
                    case .output(let stream, let offset, let data):
                        reply(.delegateOutput(cid: cid, stream: stream.rawValue, offset: offset, data: data))
                        if !follow, !ended, offset + Int64(data.count) >= stopAt { return finish(.ack(cid: cid)) }
                    case .exited(let exit), .serviceDied(let exit):
                        return finish(follow ? .delegateExit(cid: cid, status: exit.cliStatus) : .ack(cid: cid))
                    case .queued, .started:
                        break
                    }
                }
                finish(.ack(cid: cid))
            } catch {
                finish(Self.refusal(cid: cid, Self.named(error, host: record.host)))
            }
        }
        guard let timeout else { return }
        expire(after: timeout, record, cid: cid) {
            guard !done else { return false }
            replay.cancel()
            return true
        } reply: { finish($0) }
    }

    /// After `seconds`, answers `wait_timeout` unless `claim` says the wait already ended. Only
    /// the wait gives up: the run carries on, and the agent can wait again.
    private func expire(after seconds: TimeInterval, _ record: DelegatedRun, cid: Int, claim: @escaping () -> Bool,
                        reply: @escaping (ServerFrame) -> Void) {
        Task { @MainActor in
            try? await self.deps.sleep(seconds)
            guard claim() else { return }
            reply(.err(cid: cid, code: "wait_timeout",
                       message: "\(record.id) is still running on \(record.host) after \(Int(seconds))s — flightdeck wait \(record.id) again, or flightdeck logs \(record.id)"))
        }
    }

    /// The live watcher for `record`, starting one for a run this app instance did not start
    /// (one from before a relaunch) or restarting one that lost its link, so `wait` still
    /// learns how it ends.
    private func ensureLive(_ record: DelegatedRun) throws -> LiveRun {
        let liveRun = try live[record.id] ?? LiveRun(link: link(for: record))
        live[record.id] = liveRun
        if liveRun.ended != nil || record.state == .exited || record.state == .died { return liveRun }
        monitor(record.id, liveRun, fetch: record.request.fetch, include: record.request.include)
        return liveRun
    }

    // MARK: Services

    private func down(_ record: DelegatedRun) async throws {
        _ = try await hostRequest(.serviceDown(service: record.hostRunID), on: try link(for: record))
        live[record.id]?.reservation?.release()
        registry.update(record.id) { $0.state = .exited }
    }

    /// `flightdeck sync <service>` (§6.2): re-applies the current snapshot to the service's
    /// pinned checkout, or restarts it when its recipe says `restart_on_sync`.
    private func sync(_ record: DelegatedRun, owner: UUID?, cid: Int, reply: @escaping (ServerFrame) -> Void) async throws {
        let worktree = URL(fileURLWithPath: record.worktree)
        let config = try loadConfig(worktree)
        if let name = record.recipe, config?.recipes[name]?.restartOnSync == true {
            try await down(record)
            return try await start(record.request, mode: .up, owner: owner, cid: cid, reply: reply)
        }
        let link = try link(for: record)
        let include = (config?.include ?? []) + record.request.include
        do {
            let snapshot = try await deps.snapshots.snapshot(worktree: worktree, host: record.host, include: include)
            try await push(snapshot, from: worktree, to: link)
            _ = try await hostRequest(.serviceSync(service: record.hostRunID, ref: snapshot), on: link)
        } catch {
            throw Self.named(error, host: record.host)
        }
        reply(.ack(cid: cid))
    }

    // MARK: Recipes

    private func config(cwd: String) throws -> (worktree: URL, config: DelegateConfig) {
        let worktree = try locate(cwd).worktree
        return (worktree, try loadConfig(worktree) ?? DelegateConfig())
    }

    private func check(cwd: String) -> [String] {
        do {
            let (_, config) = try config(cwd: cwd)
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
            throw DelegationFailure(code: "invalid_recipe", message: "apply must be review or auto, got \(wire.apply)")
        }
        for port in wire.ports { _ = try ports(recipe: [port], cli: []) }
        return Recipe(host: wire.host, run: wire.run, down: wire.down, screen: wire.screen, long: wire.long,
                      service: wire.service, restartOnSync: wire.restartOnSync, fetch: wire.fetch,
                      ports: wire.ports, env: wire.env, apply: apply, pool: wire.pool)
    }

    // MARK: Resolution

    private func locate(_ cwd: String) throws -> (worktree: URL, subdir: String) {
        do { return try deps.worktrees.locate(cwd: URL(fileURLWithPath: cwd)) } catch {
            throw DelegationFailure(code: "not_a_repo", message: "\(cwd) is not in a git worktree — delegation syncs a git checkout; cd into one")
        }
    }

    private func loadConfig(_ worktree: URL) throws -> DelegateConfig? {
        do { return try deps.config.load(worktree: worktree) } catch {
            throw DelegationFailure(code: "invalid_config",
                                    message: ".flightdeck/delegate.toml: \(Self.describe(error)) — flightdeck recipe check")
        }
    }

    /// §5: `--on`, then the recipe's host, then the route's recipe's (the same lookup), then
    /// `default_host`; with none, a failure that lists what is paired.
    private func resolveHost(_ name: String?) throws -> String {
        if let name { return name }
        let paired = deps.hosts.hostNames
        guard !paired.isEmpty else {
            throw DelegationFailure(code: "no_host", message: "no hosts are paired — pair one in Settings › Hosts, then rerun with --on <host>")
        }
        throw DelegationFailure(code: "no_host",
                                message: "no host given and no default_host in .flightdeck/delegate.toml — rerun with --on \(paired.joined(separator: "|"))")
    }

    private func link(for record: DelegatedRun) throws -> any HostLinking {
        if let liveRun = live[record.id] { return liveRun.link }
        return try deps.hosts.link(named: record.host)
    }

    /// A run or service named by id, which must be the caller's own: another tab's run is
    /// `not_found` rather than "not yours", so one agent cannot even probe another's ids.
    private func visibleRun(_ id: String, owner: UUID?) throws -> DelegatedRun {
        guard let record = registry.run(id), record.isVisible(to: owner) else {
            throw DelegationFailure(code: "not_found", message: "no run \(id) in this session — flightdeck ps lists them")
        }
        return record
    }

    private func finishedRun(_ id: String, owner: UUID?) throws -> DelegatedRun {
        let record = try visibleRun(id, owner: owner)
        guard record.state == .exited || record.state == .died else {
            throw DelegationFailure(code: "still_running", message: "\(id) is still running on \(record.host) — flightdeck wait \(id) first")
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
        throw DelegationFailure(code: "not_found", message: "no running service \(name) in this session — flightdeck ps lists them")
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
            throw DelegationFailure(code: "no_command", message: "nothing to run — name a recipe, or give the command after --")
        }
        return argv.count == 1 ? argv[0] : argv.map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%_+=:,./-"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The recipe's ports, with a CLI `--port` replacing the recipe's entry for the same
    /// remote port (§6.2) rather than forwarding it twice.
    static func ports(recipe: [String], cli: [String]) throws -> [PortMapping] {
        func parse(_ text: String) throws -> PortMapping {
            do { return try PortMapping.parse(text) } catch {
                throw DelegationFailure(code: "invalid_port", message: "\(text) is not a port mapping — use N, L:R or auto:R")
            }
        }
        let overrides = try cli.map(parse)
        let kept = try recipe.map(parse).filter { mapping in !overrides.contains { $0.remote == mapping.remote } }
        return kept + overrides
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
            let handle = try FileHandle(forReadingFrom: bundle)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try await channel.write(chunk)
            }
            await channel.finish()
        } catch {
            channel.cancel()
            _ = try? await pushed
            throw error
        }
        _ = try await pushed
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
            let ours = registry.runs.first { $0.host == host && $0.hostRunID == holder.runID }?.id
            return "waiting for \(host)'s screen — held by \(ours ?? holder.runID) (session \"\(holder.session)\")"
        }
    }

    /// Every host request goes through here, so a host's `err` becomes its §5 line, naming the
    /// host and what to do, at one place.
    private func hostRequest(_ request: DelegationRequest, on link: any HostLinking) async throws -> DelegationReply {
        do { return try await link.request(request) } catch HostLinkError.remote(let code, let message) {
            throw DelegationFailure(code: code, message: Self.hostLine(code: code, message: message, host: link.name))
        }
    }

    private static func unexpected(_ host: String, _ op: String) -> DelegationFailure {
        DelegationFailure(code: "unexpected_reply", message: "\(host) answered \(op) with something else — update Flight Deck on both machines")
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
        case "unsupported", "not_implemented": return "\(host) does not support this yet — update Flight Deck on \(host)"
        default: return "\(host): \(message)"
        }
    }

    /// A `[[route]]` match with `fnmatch` semantics (`*` crosses `/` and spaces), the same rule
    /// the CLI's `route-exec` applies. For a `DelegateConfigLoading` that has no matcher of its
    /// own; C8 can swap in C4's `RouteMatcher`, but then must swap the CLI's in step with it.
    nonisolated static func fnmatchRoute(_ argv: [String], _ routes: [Route]) -> String? {
        let joined = argv.joined(separator: " ")
        return routes.first { fnmatch($0.match, joined, 0) == 0 }?.recipe
    }

    // MARK: Errors

    /// The `err` frame for a failure: a `DelegationFailure` verbatim, anything else wrapped
    /// so the CLI still prints one `flightdeck:` line.
    static func refusal(cid: Int, _ error: Error) -> ServerFrame {
        if let failure = error as? DelegationFailure {
            return .err(cid: cid, code: failure.code, message: failure.message)
        }
        return .err(cid: cid, code: "delegation_failed", message: describe(error))
    }

    /// Prefixes the host to a failure that does not already name it (§5: every 125 line names
    /// the host).
    private static func named(_ error: Error, host: String) -> Error {
        if let failure = error as? DelegationFailure {
            guard !failure.message.hasPrefix(host) else { return failure }
            return DelegationFailure(code: failure.code, message: "\(host): \(failure.message)")
        }
        return DelegationFailure(code: "delegation_failed", message: "\(host): \(describe(error))")
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? DelegationFailure { return failure.message }
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }
}

// MARK: - Git

/// `WorktreeLocating` through the `git` CLI, as everything in delegation reaches git.
struct GitWorktreeLocator: WorktreeLocating {
    func locate(cwd: URL) throws -> (worktree: URL, subdir: String) {
        let lines = try git(["rev-parse", "--show-toplevel", "--show-prefix"], in: cwd)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let root = lines.first, !root.isEmpty else {
            throw DelegationFailure(code: "not_a_repo", message: "\(cwd.path) is not in a git worktree")
        }
        let prefix = lines.count > 1 ? lines[1] : ""
        return (URL(fileURLWithPath: root), prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
    }

    func ignored(_ paths: [String], in worktree: URL) -> Set<String> {
        guard !paths.isEmpty,
              let out = try? git(["check-ignore", "--stdin"], in: worktree, input: paths.joined(separator: "\n") + "\n",
                                 okStatuses: [0, 1])
        else { return [] }
        return Set(out.split(separator: "\n").map(String.init))
    }

    private func git(_ args: [String], in dir: URL, input: String? = nil, okStatuses: Set<Int32> = [0]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        let inPipe = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = inPipe
        try process.run()
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard okStatuses.contains(process.terminationStatus) else {
            throw DelegationFailure(code: "git_failed", message: "git \(args.first ?? "") failed in \(dir.path)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
