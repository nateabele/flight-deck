import FleetKit
import Foundation

/// What a delegation verb needs from the `CLIRunner` around it: the socket, the outputs, and
/// the exit. Closures rather than the runner itself so this state machine is driven frame by
/// frame in a test with nothing else running, as `CLIRunner` is.
struct DelegateRunnerHooks {
    var send: (FleetRequest) -> Int
    /// Registers the handler for every frame on `cid` (a stream draws several).
    var expect: (_ cid: Int, _ handler: @escaping (ServerFrame) -> Void) -> Void
    var out: (String) -> Void
    var err: (String) -> Void
    /// Raw run output, straight to the CLI's own stdout (`stdout`, `pty`) or stderr, with no
    /// newline added: a delegated `make` must print exactly what a local one would. Throws when
    /// the write fails — EPIPE, for `flightdeck run … | head`.
    var write: (_ stream: String, _ data: Data) throws -> Void
    var finish: (Int32) -> Void
    /// `route-exec`'s fall-through: replaces the process with the real binary.
    var execReal: (_ argv0: String, _ args: [String]) -> Void
    /// Starts a fresh connection after a drop; the runner's `reattach` follows its snapshot.
    var reconnect: () -> Void
    /// The runner's timer, for retrying a reattach and bounding a reconnect.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { _, _ in }
}

/// One delegation verb (spec §5) from parse to exit.
///
/// Exit statuses (§5): the remote command's status for a run that ended (`delegateExit`,
/// already mapped to `128+n` for a signal); **125** for any delegation failure, after one
/// `flightdeck: …` line; **124** for a `wait` that timed out with the run still going; **141**
/// when the reader of our stdout went away (the shell's SIGPIPE status); 0 for a detached run,
/// a service, and every listing.
final class DelegateCommandRunner {
    /// How many reconnects a run that lost the app gets before the CLI gives up on it (one a
    /// second): long enough to outlast an app relaunch, short of hanging an agent forever.
    static let reconnectLimit = 30
    /// How long a reconnected socket may take to deliver its snapshot before the CLI gives up.
    static let snapshotDeadline: TimeInterval = 10
    /// Refusals a reattach retries rather than reports: the app is back but its link to the
    /// host is not yet (right after a relaunch). They share `reconnectLimit`.
    static let retriable: Set<String> = ["host_unavailable", "host_offline"]

    private let command: DelegateCommand
    private let cwd: String
    private let columns: Int?
    private let rows: Int?
    private let wantsJSON: Bool
    private let hooks: DelegateRunnerHooks

    /// The run this CLI is attached to, once `delegateStarted` names it: what Ctrl-C stops and
    /// what a reconnect resumes.
    private var runID: String?
    /// One past the last output byte written, so a resume after a drop neither repeats nor
    /// skips a byte (`delegate.wait {from}`).
    private var nextOffset: Int64 = 0
    private var interrupted = false
    /// Ctrl-C came before `delegateStarted` named the run; the stop goes out with the id.
    private var stopWhenStarted = false
    private var reconnects = 0
    /// Bumped per drop, so only the latest reconnect's snapshot deadline can fire.
    private var generation = 0
    private var awaitingSnapshot = false
    /// On a reattach path — after a drop or a `slow_reader` — where every failure must still
    /// say how to get the run back.
    private var resuming = false
    private var finished = false
    /// `route-exec` has matched and handed the command to the app: from here a lost app is a
    /// lost run (125), no longer a reason to run the real binary — which would run it twice.
    private(set) var isDelegating = false

    init(command: DelegateCommand, cwd: String, columns: Int?, rows: Int?, wantsJSON: Bool,
         hooks: DelegateRunnerHooks) {
        self.command = command
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
        self.wantsJSON = wantsJSON
        self.hooks = hooks
    }

    /// The verbs whose lost app is a lost run, reported as a delegation failure (125) naming
    /// the next step, never as a bare "disconnected" (1) or "cannot reach" (69).
    static func isRunVerb(_ command: DelegateCommand) -> Bool {
        switch command {
        case .run, .exec, .wait: return true
        default: return false
        }
    }

    func start() {
        switch command {
        case .run(let run):
            if run.detach { return stream(.run(located(run)), detached: true) }
            // A `long` or `service` recipe detaches (§6.1, §6.2), and only the project's
            // `delegate.toml` says which recipe is which — including one a route picks — so the
            // CLI reads it first. The CLI is the one owner of that decision: it is sent as
            // `detach`, and the app ends the stream on `delegateStarted` exactly when it says.
            recipes { book in
                var run = run
                let name = run.recipe ?? book.flatMap { DelegateRouting.recipe(for: run.command, in: $0.routes) }
                run.detach = book.map { Self.detaches(name, in: $0) } ?? false
                self.stream(.run(self.located(run)), detached: run.detach)
            }
        case .exec(let run):
            // Never routed, so there is no recipe to read: it detaches only on `--detach`.
            stream(.exec(located(run)), detached: run.detach)
        case .up(let run):
            stream(.up(located(run)), detached: true)
        case .restart(let service):
            stream(.restart(service: service, cwd: cwd), detached: true)
        case .wait(let run, let timeout, let from):
            runID = run
            nextOffset = from ?? 0
            stream(.wait(run: run, timeout: timeout, from: from), detached: false)
        case .logs(let run, let follow, let from):
            runID = run
            nextOffset = from ?? 0
            stream(.logs(run: run, follow: follow, from: from), detached: false)
        case .down(let service):
            acknowledged(.down(service: service, cwd: cwd))
        case .sync(let service):
            // `restart_on_sync` answers as `restart` does; a plain sync answers `ack`.
            stream(.sync(service: service, cwd: cwd), detached: true)
        case .stop(let run):
            acknowledged(.stop(run: run))
        case .recipeAdd(let recipe):
            acknowledged(.recipeAdd(cwd: cwd, name: recipe.name, recipe: recipe))
        case .hostPrune(let host, let repo):
            acknowledged(.hostPrune(host: host, repo: repo))
        case .hostDisk(nil):
            everyHostsDisk()
        case .ps, .diff, .apply, .recipeList, .recipeCheck, .hostDisk:
            single()
        case .routeExec(let argv0, let args):
            routeExec(argv0, args)
        }
    }

    static func detaches(_ recipe: String?, in book: WireRecipeBook) -> Bool {
        guard let found = book.recipes.first(where: { $0.name == recipe }) else { return false }
        return found.long || found.service
    }

    /// Ctrl-C (§6.1: "the CLI forwards SIGINT"). On an attached run, the first stops it on the
    /// host — at once, or as soon as `delegateStarted` names it — and keeps streaming until it
    /// ends, so the agent still sees how it ended; a second leaves without waiting, and the
    /// host's own INT → TERM → KILL escalation carries on. On `wait` and `logs`, Ctrl-C only
    /// stops watching: a run the agent detached is not cancelled by giving up on it.
    func interrupt() {
        guard !finished else { return }
        switch command {
        case .wait, .logs:
            if let runID { hooks.err("flightdeck: stopped watching \(runID) — it carries on; flightdeck wait \(runID)") }
            return finish(130)
        default:
            break
        }
        guard !interrupted else { return finish(130) }
        interrupted = true
        guard let runID else {
            stopWhenStarted = true
            hooks.err("flightdeck: stopping the run as soon as it starts — Ctrl-C again to stop waiting")
            return
        }
        stop(runID)
    }

    private func stop(_ runID: String) {
        hooks.err("flightdeck: stopping \(runID) — Ctrl-C again to stop waiting")
        _ = hooks.send(.delegate(.stop(run: runID)))
    }

    /// The control socket dropped. An attached run carries on on the host, so the CLI comes
    /// back for it: after the reconnect, `reattach` resumes from the next unseen byte. A run
    /// verb with nothing to resume yet is a delegation failure (125). Returns false when this
    /// verb has no say, and the runner fails as it would for any other command.
    func disconnected() -> Bool {
        guard !finished else { return true }
        guard let runID, isAttachedStream else {
            guard Self.isRunVerb(command) || isDelegating else { return false }
            refused("disconnected", "lost Flight Deck before the run started — check flightdeck ps, then rerun")
            return true
        }
        resuming = true
        reconnects += 1
        guard reconnects <= Self.reconnectLimit else {
            refused("disconnected", "lost Flight Deck — \(runID) carries on on the host")
            return true
        }
        generation += 1
        awaitingSnapshot = true
        let attempt = generation
        hooks.reconnect()
        hooks.schedule(1 + Self.snapshotDeadline) { self.snapshotOverdue(attempt) }
        return true
    }

    /// The reconnect connected but no snapshot came: the app is wedged, not restarting.
    private func snapshotOverdue(_ attempt: Int) {
        guard !finished, awaitingSnapshot, attempt == generation, let runID else { return }
        refused("disconnected", "Flight Deck did not answer after reconnecting — \(runID) carries on on the host")
    }

    /// The fresh connection's snapshot arrived: pick the run up where the output stopped.
    func reattach() {
        guard !finished, let runID else { return }
        awaitingSnapshot = false
        resume(runID)
    }

    /// Picks the attached run back up from `nextOffset`: after a reconnect, or after the app
    /// ended the stream because this reader fell behind (`slow_reader`). A `run`'s reattach has
    /// no timeout — it is still the same run, not a new 9-minute `wait` that exits 124. A
    /// `wait` keeps its own terms and, as before, prints no output.
    private func resume(_ runID: String) {
        resuming = true
        switch command {
        case .wait(_, let timeout, let from):
            // The user's own `wait`, on its own terms: its `--timeout`, and output only if it
            // asked for some with `--from`.
            stream(.wait(run: runID, timeout: timeout, from: from == nil ? nil : nextOffset), detached: false)
        case .logs(_, let follow, _):
            stream(.logs(run: runID, follow: follow, from: nextOffset), detached: false)
        default:
            stream(.wait(run: runID, timeout: nil, from: nextOffset, noTimeout: true), detached: false)
        }
    }

    private var isAttachedStream: Bool {
        switch command {
        case .run, .exec, .wait, .logs: return true
        case .routeExec: return isDelegating
        default: return false
        }
    }

    // MARK: Requests

    private func located(_ run: WireDelegateRun) -> WireDelegateRun {
        guard case .run(let located)? = DelegateCommand.run(run).request(cwd: cwd, columns: columns, rows: rows)
        else { return run }
        return located
    }

    /// `recipe.ls`, handing back nil on any refusal: a project with a broken `delegate.toml`
    /// still reaches the app, which then says what is wrong with it.
    private func recipes(_ then: @escaping (WireRecipeBook?) -> Void) {
        let cid = hooks.send(.delegate(.recipeList(cwd: cwd)))
        hooks.expect(cid) { frame in
            if case .recipes(_, let book) = frame { return then(book) }
            then(nil)
        }
    }

    /// A streaming request: output, notices, and one terminal frame.
    private func stream(_ request: DelegateRequest, detached: Bool) {
        let cid = hooks.send(.delegate(request))
        hooks.expect(cid) { frame in
            guard !self.finished else { return }
            switch frame {
            case .delegateStarted(_, let started):
                let first = self.runID == nil
                self.runID = started.runID
                if detached { return self.started(started) }
                if self.stopWhenStarted {
                    self.stopWhenStarted = false
                    self.stop(started.runID)
                } else if first {
                    // Once, at the start: the id an agent needs to `wait`, `logs` or `stop` the
                    // run if it loses this CLI. On stderr, so stdout stays the command's own.
                    self.hooks.err("flightdeck: \(started.runID) running on \(started.host)")
                }
            case .delegateNotice(_, let message):
                self.hooks.err("flightdeck: \(message)")
            case .delegateOutput(_, let stream, let offset, let data):
                // A resumed stream may overlap what was already written; only bytes past
                // `nextOffset` are new.
                let skip = max(0, Int(self.nextOffset - offset))
                if skip < data.count {
                    do { try self.hooks.write(stream, data.dropFirst(skip)) } catch {
                        // The reader went away (`| head`): detach quietly with the shell's
                        // SIGPIPE status. The run carries on; nothing more is printed.
                        return self.finish(141)
                    }
                }
                self.nextOffset = max(self.nextOffset, offset + Int64(data.count))
            case .delegateExit(_, let status):
                self.finish(status)
            case .ack:
                self.finish(0) // `logs` without --follow: the replay is done; a plain `sync`
            case .err(_, "slow_reader", _) where self.runID != nil:
                self.resume(self.runID!)
            case .err(_, let code, let message) where self.resuming && Self.retriable.contains(code):
                // The app is back, its link to the host not yet: try again, within the cap.
                self.reconnects += 1
                guard self.reconnects <= Self.reconnectLimit, let runID = self.runID else {
                    return self.refused(code, message)
                }
                self.hooks.schedule(1) { if !self.finished { self.resume(runID) } }
            case .err(_, let code, let message):
                self.refused(code, message)
            default:
                self.refused("unexpected_reply", nil)
            }
        }
    }

    /// The detached `delegateStarted`: the id, how to wait for it, and any forwarded port —
    /// for `auto:R`, the only place the agent learns which local port it got.
    private func started(_ started: WireDelegateStarted) {
        let service: Bool = {
            switch self.command {
            case .up, .restart, .sync: return true
            default: return false
            }
        }()
        let next = service ? "flightdeck down \(started.runID)" : "flightdeck wait \(started.runID)"
        if wantsJSON {
            hooks.out(CLIOutput.json(DetachedRun(runID: started.runID, host: started.host, ports: started.ports, next: next)))
        } else {
            var line = "\(started.runID) started on \(started.host)"
            if !started.ports.isEmpty {
                line += " — " + started.ports.map { "localhost:\($0.local) → \(started.host):\($0.remote)" }
                    .joined(separator: ", ")
            }
            hooks.out(line)
            hooks.out(service ? "\(next) stops it; flightdeck logs \(started.runID) shows its output"
                              : "\(next) for its result")
        }
        finish(0)
    }

    /// `--json`'s detached line: `WireDelegateStarted` plus the command to run next, so a
    /// script reading JSON gets the same hint a person does.
    private struct DetachedRun: Encodable {
        let runID: String
        let host: String
        let ports: [WirePortBinding]
        let next: String
    }

    private func acknowledged(_ request: DelegateRequest) {
        let cid = hooks.send(.delegate(request))
        hooks.expect(cid) { frame in
            switch frame {
            case .ack: self.finish(0)
            case .err(_, let code, let message): self.refused(code, message)
            default: self.refused("unexpected_reply", nil)
            }
        }
    }

    /// The one-reply listings.
    private func single() {
        guard let request = command.request(cwd: cwd, columns: columns, rows: rows) else { return }
        let cid = hooks.send(.delegate(request))
        hooks.expect(cid) { frame in
            switch frame {
            case .delegateRuns(_, let runs):
                self.hooks.out(self.wantsJSON ? CLIOutput.json(runs) : DelegateOutput.table(runs, now: Date()))
                self.finish(0)
            case .delegatePatch(_, let patch):
                if self.wantsJSON {
                    self.hooks.out(CLIOutput.json(patch))
                } else if let path = patch.patchPath {
                    // Over 1 MiB: the app wrote it to a file rather than the socket.
                    self.hooks.out(path)
                } else {
                    do { try self.hooks.write("stdout", Data((patch.patch ?? "").utf8)) } catch { return self.finish(141) }
                }
                self.finish(0)
            case .delegateApplied(_, let applied):
                if self.wantsJSON { self.hooks.out(CLIOutput.json(applied)) }
                guard applied.conflicts.isEmpty else {
                    // Applied, with markers: a non-zero exit so an agent looks before it builds.
                    self.hooks.err("flightdeck: applied \(applied.runID) with conflicts in \(applied.conflicts.joined(separator: ", ")) — resolve the markers")
                    return self.finish(1)
                }
                if !self.wantsJSON { self.hooks.out("applied \(applied.runID)") }
                self.finish(0)
            case .recipes(_, let book):
                self.hooks.out(self.wantsJSON ? CLIOutput.json(book) : DelegateOutput.recipes(book))
                self.finish(0)
            case .recipeCheck(_, let problems):
                if self.wantsJSON { self.hooks.out(CLIOutput.json(problems)) } else { problems.forEach(self.hooks.out) }
                self.finish(problems.isEmpty ? 0 : 1)
            case .hostDisk(_, let usage):
                self.hooks.out(self.wantsJSON ? CLIOutput.json(usage) : DelegateOutput.disk(usage))
                self.finish(0)
            case .err(_, let code, let message):
                self.refused(code, message)
            default:
                self.refused("unexpected_reply", nil)
            }
        }
    }

    /// `host ls --disk` with no host: every paired host's workspaces, one request per online
    /// host, in name order. An offline host is listed as such rather than failing the rest.
    private func everyHostsDisk() {
        let cid = hooks.send(.hostList)
        hooks.expect(cid) { frame in
            guard case .hostList(_, let hosts) = frame else {
                if case .err(_, let code, let message) = frame { return self.refused(code, message) }
                return self.refused("unexpected_reply", nil)
            }
            var remaining = hosts.sorted { $0.name < $1.name }
            var sections: [String] = []
            var json: [String: [WireWorkspaceUsage]] = [:]
            func next() {
                guard !remaining.isEmpty else {
                    self.hooks.out(self.wantsJSON ? CLIOutput.json(json)
                                                  : (sections.isEmpty ? "no hosts are paired" : sections.joined(separator: "\n\n")))
                    return self.finish(0)
                }
                let host = remaining.removeFirst()
                guard host.status == "online" else {
                    sections.append("\(host.name): \(host.status)")
                    return next()
                }
                let cid = self.hooks.send(.delegate(.hostDisk(host: host.name)))
                self.hooks.expect(cid) { frame in
                    switch frame {
                    case .hostDisk(_, let usage):
                        json[host.name] = usage
                        sections.append("\(host.name):\n" + DelegateOutput.disk(usage))
                    case .err(_, let code, let message):
                        sections.append("\(host.name): \(message ?? code)")
                    default:
                        sections.append("\(host.name): unexpected reply")
                    }
                    next()
                }
            }
            next()
        }
    }

    /// The routing shim (§8). Delegates when a `[[route]]` matches, and otherwise — no match,
    /// no `delegate.toml`, any refusal — runs the real binary, so a shim can never make a
    /// command fail that would have worked without it.
    private func routeExec(_ argv0: String, _ args: [String]) {
        let argv = [DelegateRouting.commandName(argv0)] + args
        recipes { book in
            guard let book, let name = DelegateRouting.recipe(for: argv, in: book.routes) else {
                return self.hooks.execReal(argv0, args)
            }
            // No `recipe` on the wire: the app routes the argv itself, which runs the argv as
            // given with the recipe's settings, rather than appending it to the recipe's `run`.
            let detach = Self.detaches(name, in: book)
            let run = WireDelegateRun(cwd: self.cwd, command: argv, detach: detach)
            self.isDelegating = true
            self.stream(.run(run), detached: detach)
        }
    }

    // MARK: Exit

    /// Every delegation failure is 125 and one `flightdeck:` line (§5); a `wait` that timed
    /// out is 124 with the run still going.
    private func refused(_ code: String, _ message: String?) {
        var line = message ?? code
        // On a reattach the run is still going, wherever this CLI lost it: the line ends on
        // the one step that gets it back.
        if resuming, let runID, !line.contains("flightdeck wait \(runID)") { line += " — flightdeck wait \(runID)" }
        hooks.err("flightdeck: \(line)")
        switch code {
        case "wait_timeout": finish(124)
        // Not a failure to delegate: the run is fine, it just left nothing to apply.
        case "nothing_to_apply": finish(1)
        default: finish(125)
        }
    }

    private func finish(_ status: Int32) {
        guard !finished else { return }
        finished = true
        hooks.finish(status)
    }
}

/// Everything the delegation verbs print for a human, as strings.
enum DelegateOutput {
    static func table(_ runs: [WireDelegateRunRow], now: Date) -> String {
        guard !runs.isEmpty else { return "no delegated runs" }
        var rows = [["ID", "HOST", "KIND", "STATE", "STATUS", "PORTS", "STARTED", "COMMAND"]]
        for run in runs {
            rows.append([
                run.runID, run.host, run.kind, run.state, run.status.map(String.init) ?? "-",
                run.ports.isEmpty ? "-" : run.ports.joined(separator: ","),
                run.startedAt.map { CLIOutput.relative($0, now: now) } ?? "-",
                run.recipe.map { "[\($0)] \(run.command)" } ?? run.command,
            ])
        }
        return columns(rows)
    }

    static func recipes(_ book: WireRecipeBook) -> String {
        var lines = ["default host: \(book.defaultHost ?? "-")"]
        if !book.include.isEmpty { lines.append("include: \(book.include.joined(separator: ", "))") }
        if book.recipes.isEmpty { lines.append("no recipes — flightdeck recipe add NAME --run CMD") }
        for recipe in book.recipes {
            var flags = [recipe.host.map { "on \($0)" }, recipe.service ? "service" : nil, recipe.long ? "long" : nil,
                         recipe.screen ? "screen" : nil, recipe.apply == "auto" ? "apply auto" : nil].compactMap { $0 }
            if !recipe.ports.isEmpty { flags.append("ports \(recipe.ports.joined(separator: ","))") }
            lines.append("\(recipe.name): \(recipe.run)" + (flags.isEmpty ? "" : "  (\(flags.joined(separator: ", ")))"))
        }
        for route in book.routes { lines.append("route \"\(route.match)\" → \(route.recipe)") }
        return lines.joined(separator: "\n")
    }

    static func disk(_ usage: [WireWorkspaceUsage]) -> String {
        guard !usage.isEmpty else { return "no workspaces" }
        let size = ByteCountFormatter()
        size.countStyle = .file
        var rows = [["WORKTREE", "REPO", "SIZE"]]
        for entry in usage {
            rows.append([entry.worktreeName, String(entry.repoRoot.prefix(12)), size.string(fromByteCount: entry.bytes)])
        }
        return columns(rows)
    }

    /// `CLIOutput`'s column layout (private there): left-aligned, two spaces apart.
    private static func columns(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { cells in
            cells.enumerated().map { column, cell in cell.padding(toLength: widths[column], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}
