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
    /// newline added: a delegated `make` must print exactly what a local one would.
    var write: (_ stream: String, _ data: Data) -> Void
    var finish: (Int32) -> Void
    /// `route-exec`'s fall-through: replaces the process with the real binary.
    var execReal: (_ argv0: String, _ args: [String]) -> Void
    /// Starts a fresh connection after a drop; the runner's `reattach` follows its snapshot.
    var reconnect: () -> Void
}

/// One delegation verb (spec §5) from parse to exit.
///
/// Exit statuses (§5): the remote command's status for a run that ended (`delegateExit`,
/// already mapped to `128+n` for a signal); **125** for any delegation failure, after one
/// `flightdeck: …` line; **124** for a `wait` that timed out with the run still going; 0 for
/// a detached run, a service, and every listing.
final class DelegateCommandRunner {
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

    func start() {
        switch command {
        case .run(let run):
            if run.detach { return stream(.run(located(run)), detached: true) }
            // A `long` recipe detaches (§6.1), and only the project's `delegate.toml` says
            // which recipe is long — including one a route picks — so the CLI reads it first.
            // Detaching is decided here, once, and sent as `detach`: the app then ends the
            // stream on `delegateStarted` exactly when this CLI expects it to.
            recipes { book in
                var run = run
                let name = run.recipe ?? book.flatMap { DelegateRouting.recipe(for: run.command, in: $0.routes) }
                run.detach = book?.recipes.first { $0.name == name }?.long == true
                self.stream(.run(self.located(run)), detached: run.detach)
            }
        case .exec(let run):
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
            stream(.logs(run: run, follow: follow, from: from), detached: false)
        case .down(let service):
            acknowledged(.down(service: service, cwd: cwd))
        case .sync(let service):
            acknowledged(.sync(service: service, cwd: cwd))
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

    /// Ctrl-C (§6.1: "the CLI forwards SIGINT"). The first stops the attached run on the host
    /// and keeps streaming until it ends, so the agent still sees how it ended; a second
    /// leaves without waiting, and the host's own INT → TERM → KILL escalation carries on.
    func interrupt() {
        guard !finished else { return }
        guard let runID, !interrupted else { return finish(130) }
        interrupted = true
        hooks.err("flightdeck: stopping \(runID) — Ctrl-C again to stop waiting")
        _ = hooks.send(.delegate(.stop(run: runID)))
    }

    /// The control socket dropped. An attached run carries on on the host, so the CLI comes
    /// back for it: after the reconnect, `reattach` resumes from the next unseen byte.
    /// Returns false when there is nothing to resume, and the runner fails as it would for any
    /// other command.
    func disconnected() -> Bool {
        guard !finished, runID != nil, isAttachedStream else { return false }
        hooks.reconnect()
        return true
    }

    /// The fresh connection's snapshot arrived: pick the run up where the output stopped.
    func reattach() {
        guard !finished, let runID else { return }
        stream(.wait(run: runID, timeout: nil, from: nextOffset), detached: false)
    }

    private var isAttachedStream: Bool {
        switch command {
        case .run, .exec, .wait, .routeExec: return true
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
                self.runID = started.runID
                if detached { self.started(started) }
            case .delegateNotice(_, let message):
                self.hooks.err("flightdeck: \(message)")
            case .delegateOutput(_, let stream, let offset, let data):
                // A resumed stream may overlap what was already written; only bytes past
                // `nextOffset` are new.
                let skip = max(0, Int(self.nextOffset - offset))
                if skip < data.count { self.hooks.write(stream, data.dropFirst(skip)) }
                self.nextOffset = max(self.nextOffset, offset + Int64(data.count))
            case .delegateExit(_, let status):
                self.finish(status)
            case .ack:
                self.finish(0) // `logs` without --follow: the replay is done
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
        if wantsJSON {
            hooks.out(CLIOutput.json(started))
        } else {
            let service = { if case .up = self.command { return true }; if case .restart = self.command { return true }; return false }()
            var line = "\(started.runID) started on \(started.host)"
            if !started.ports.isEmpty {
                line += " — " + started.ports.map { "localhost:\($0.local) → \(started.host):\($0.remote)" }
                    .joined(separator: ", ")
            }
            hooks.out(line)
            hooks.out(service ? "flightdeck down \(started.runID) stops it; flightdeck logs \(started.runID) shows its output"
                              : "flightdeck wait \(started.runID) for its result")
        }
        finish(0)
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
                    self.hooks.write("stdout", Data((patch.patch ?? "").utf8))
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
            let long = book.recipes.first { $0.name == name }?.long == true
            let run = WireDelegateRun(cwd: self.cwd, command: argv, detach: long)
            self.isDelegating = true
            self.stream(.run(run), detached: long)
        }
    }

    // MARK: Exit

    /// Every delegation failure is 125 and one `flightdeck:` line (§5); a `wait` that timed
    /// out is 124 with the run still going.
    private func refused(_ code: String, _ message: String?) {
        hooks.err("flightdeck: \(message ?? code)")
        finish(code == "wait_timeout" ? 124 : 125)
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
