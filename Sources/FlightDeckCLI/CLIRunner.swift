import FleetKit
import Foundation
import Network

/// What the process around the runner knows that the command line does not.
struct CLIContext {
    /// `FLIGHT_DECK_SESSION_ID`, the tab this CLI is running inside, which `self` names.
    var selfID: UUID?
    /// For `.`/`here` project resolution.
    var cwd: String
    var json: Bool
    /// Only a terminal gets human output (`ls`'s table, `prompt`'s numbered list, `new`'s bare
    /// id): a pipe gets JSON even without `--json`, so a script that forgot the flag still
    /// reads something parseable.
    var isTTY: Bool
}

/// One `flightdeck` invocation, as a state machine over frames: connect, take the fleet
/// snapshot, execute the command, finish exactly once.
///
/// Transport-agnostic and clock-agnostic — `schedule` is the only timer — so every path,
/// reconnect and timeout included, is driven synchronously by a test.
///
/// **Keeps itself alive on purpose.** The transport's callbacks capture the runner strongly,
/// so the runner lives as long as its connection does without the caller holding it; a weak
/// capture would let `_ = CLIRunner(…).run()` deallocate before the first frame arrived and
/// the command would silently never happen. A CLI process exits on `finish`, which is what
/// ends the cycle.
final class CLIRunner {
    /// Between a dropped `tail`/`wait` and its reconnect. Long enough not to spin against a Flight
    /// Deck that is still relaunching, short enough that a restart loses no visible time.
    private static let reconnectDelay: TimeInterval = 1
    /// How long `new` waits for its tab to appear after asking. `ack` means dispatched, not
    /// done, so without a bound a launch the Mac never completes would hang a script forever.
    private static let launchTimeout: TimeInterval = 30

    private let invocation: CLIInvocation
    private let transport: CLITransport
    private let context: CLIContext
    private let out: (String) -> Void
    private let err: (String) -> Void
    private let onFinish: (Int32) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    private var fleet = FleetSnapshot.empty
    private var lastSeq = 0
    /// The socket reached `.ready`, or any frame arrived. Before that, a disconnect is an
    /// unreachable Mac (69); after it, a dropped connection. `onReady` is needed as well as
    /// frames: a caught-up `tail --since` resume is answered with an empty replay, so a quiet
    /// fleet sends nothing at all, and judging by frames alone turned an app restart into 69.
    private var reachedMac = false
    private var dispatched = false
    /// Every exit path goes through `finish`, and this makes a second one a no-op — a late
    /// reply, a timeout racing an ack, or a disconnect after the answer must never print a
    /// second verdict or overwrite the exit code.
    private var finished = false

    /// Handlers for the replies this runner is waiting on, keyed by the `cid` each went out on.
    private var replies: [Int: (ServerFrame) -> Void] = [:]
    private var onEvent: ((FleetEvent) -> Void)?
    /// A snapshot after the first: a mid-connection reset, which `wait` re-evaluates against
    /// and `raw hello` is waiting to print.
    private var onSnapshot: ((ServerFrame) -> Void)?

    private var tailTarget: UUID?
    private var tailSawSnapshot = false
    private var rawFrame: ClientFrame?

    private var wantsJSON: Bool { context.json || invocation.json || !context.isTTY }

    init(invocation: CLIInvocation, transport: CLITransport, context: CLIContext,
         out: @escaping (String) -> Void, err: @escaping (String) -> Void,
         finish: @escaping (Int32) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.invocation = invocation
        self.transport = transport
        self.context = context
        self.out = out
        self.err = err
        self.onFinish = finish
        self.schedule = schedule
    }

    func run() {
        // Checks that need no fleet run before connecting: a typo is a usage error whether or
        // not Flight Deck is up, and reporting it as "cannot reach" (69) would send someone
        // debugging the socket instead of their command line.
        switch invocation.command {
        case .help:
            return finish(0)
        case .raw(let text):
            guard let frame = try? JSONDecoder().decode(ClientFrame.self, from: Data(text.utf8)) else {
                return usage("raw: not a client frame: \(text)")
            }
            rawFrame = frame
        case .tail(let token, let since, _):
            lastSeq = since ?? 0
            if let token {
                // A resume (`--since`) is answered with replayed events and no snapshot, so a
                // title has nothing to be resolved against before the events it filters
                // arrive. `self` and a full id need no fleet, so only those are allowed there.
                if token == "self" {
                    guard let selfID = context.selfID else { return resolveFailed(.noSelf, "session") }
                    tailTarget = selfID
                } else if let id = UUID(uuidString: token) {
                    tailTarget = id
                } else if since != nil {
                    return usage("tail: --since with --session needs a full session id or self")
                }
            }
        case .wait(_, _, let timeout?), .send(_, _, true, let timeout?):
            schedule(timeout) { self.fail("timed_out") }
        default:
            break
        }
        transport.onReady = { self.reachedMac = true }
        transport.onFrame = { self.handle($0) }
        transport.onDisconnect = { self.disconnected($0) }
        transport.connect(lastSeq: lastSeq)
    }

    // MARK: Frames

    private func handle(_ frame: ServerFrame) {
        guard !finished else { return }
        reachedMac = true
        switch frame {
        case .snapshot(let seq, let snapshot, _):
            lastSeq = seq
            fleet = snapshot
        case .event(let seq, let event):
            lastSeq = seq
            fleet = fleet.applying([event])
        default:
            break
        }

        if case .tail(let token, _, let noSnapshot) = invocation.command {
            return tail(frame, token: token, noSnapshot: noSnapshot)
        }
        guard dispatched else {
            // At `lastSeq: 0` the snapshot is always the first frame, so nothing is skipped here.
            guard case .snapshot = frame else { return }
            dispatched = true
            return dispatch()
        }
        switch frame {
        case .snapshot: onSnapshot?(frame)
        case .event(_, let event): onEvent?(event)
        default:
            if let cid = frame.correlationID, let reply = replies[cid] { reply(frame) }
        }
    }

    private func disconnected(_ error: Error?) {
        guard !finished else { return }
        // Checked before `reachedMac`: the sandbox refuses the `connect()` syscall itself, so
        // this fires on the very first attempt, and it means something a retry cannot fix —
        // unlike an ordinary drop, `tail`/`wait` must not schedule a reconnect against it either.
        if Self.isSandboxRefusal(error) { return finish(77) }
        // The 69 message names the socket path, which only the main program knows.
        guard reachedMac else { return finish(69) }
        switch invocation.command {
        case .tail, .wait:
            // Both outlive an app restart: resume from the last sequence seen, so `tail`'s
            // consumer sees either the missed events or an explicit re-snapshot, never a gap,
            // and `wait` re-evaluates against them rather than dying on the very restart an
            // orchestrator may be waiting out. `dispatched` stays set, so the replay reaches
            // `wait`'s own `onEvent`/`onSnapshot` rather than dispatching it a second time.
            schedule(Self.reconnectDelay) {
                guard !self.finished else { return }
                self.transport.connect(lastSeq: self.lastSeq)
            }
        default:
            fail("disconnected")
        }
    }

    /// EPERM/EACCES on the control socket's `connect()` is the agent's own sandbox denying the
    /// syscall, not Flight Deck being unreachable — the two are indistinguishable by symptom
    /// (both surface as a disconnect with no frame ever received) but need different advice, so
    /// this is the one place both possible shapes of "it's the sandbox" are recognized: the
    /// `NWError` `FleetClient` hands back from `NWConnection`'s own state, and a `POSIXError`
    /// in case a future transport surfaces the raw syscall error instead.
    private static func isSandboxRefusal(_ error: Error?) -> Bool {
        if case .posix(let code)? = error as? NWError { return code == .EPERM || code == .EACCES }
        if let posixError = error as? POSIXError { return posixError.code == .EPERM || posixError.code == .EACCES }
        return false
    }

    private func dispatch() {
        switch invocation.command {
        case .help, .tail:
            break
        case .ls(let project):
            ls(project)
        case .wait(let token, let condition, _):
            wait(token, condition)
        case .send(let token, let text, let wait, _):
            if wait { return sendAndWait(token, text) }
            command(on: token) { .prompt(id: $0, token: UUID(), text: text) }
        case .close(let token):
            command(on: token) { .closeSession(id: $0) }
        case .read(let token):
            command(on: token) { .markRead(id: $0) }
        case .unread(let token):
            command(on: token) { .markUnread(id: $0) }
        case .rename(let token, let title):
            command(on: token) { .renameSession(id: $0, title: title) }
        case .abort(let token):
            command(on: token) { .abortPrompt(id: $0, token: UUID()) }
        case .reopen(let id):
            // Not resolved: a closed tab is by definition absent from the fleet.
            send(.reopenClosed(session: id))
        case .collapse(let token, let collapsed):
            guard let id = project(token) else { return }
            send(.setProjectCollapsed(id: id, isCollapsed: collapsed))
        case .new(let token, let agent, let account):
            new(token, agent: agent, account: account)
        case .prompt(let token):
            derivePrompt(token) { _, prompt in
                self.out(self.wantsJSON ? CLIOutput.promptJSON(prompt) : CLIOutput.prompt(prompt))
                self.finish(0)
            }
        case .answer(let token, let choice, let call):
            derivePrompt(token) { session, prompt in
                self.answer(prompt, session: session.id, choice: choice, call: call)
            }
        case .planResolve(let token, let approve, let feedback):
            plan(token) { .resolvePlan(id: $0, token: UUID(), call: $1, approve: approve, feedback: feedback) }
        case .planAnnotate(let token, let text, let block):
            plan(token) { .annotatePlan(id: $0, token: UUID(), call: $1, text: text, block: block) }
        case .timeline(let token, let anchor, let limit):
            guard let id = sessionID(token) else { return }
            request(.timeline(session: id, anchor: anchor, limit: limit))
        case .search(let query, let limit):
            request(.search(query: query, limit: limit))
        case .closed:
            request(.recentlyClosed)
        case .options(let token):
            guard let id = project(token) else { return }
            request(.newSessionOptions(project: id))
        case .open(let conversation, let path):
            request(.openConversation(conversationID: conversation, projectPath: path))
        case .raw:
            raw()
        }
    }

    // MARK: Commands

    private func ls(_ token: String?) {
        var shown = fleet
        if let token {
            guard let id = project(token) else { return }
            shown.projects = shown.projects.filter { $0.id == id }
        }
        out(!wantsJSON && context.isTTY ? CLIOutput.table(shown) : CLIOutput.json(shown))
        finish(0)
    }

    private func tail(_ frame: ServerFrame, token: String?, noSnapshot: Bool) {
        switch frame {
        case .snapshot(_, _, let reason):
            let first = !tailSawSnapshot
            tailSawSnapshot = true
            if first, tailTarget == nil, let token {
                guard let id = sessionID(token) else { return }
                tailTarget = id
            }
            // `--no-snapshot` suppresses only the opening state. Any later snapshot, and one
            // answering a `--since` that is too old, is a reset the consumer must see — its
            // held state is no longer the fleet's.
            if noSnapshot, first, reason == .initial { return }
            out(CLIOutput.line(frame))
        case .event(_, let event):
            if let tailTarget, CLIOutput.eventSession(event) != tailTarget { return }
            out(CLIOutput.line(frame))
        default:
            break // `tail` sends nothing, so no reply is its own.
        }
    }

    private func wait(_ token: String, _ condition: String) {
        let id: UUID
        switch CLISessionResolver.session(token, in: fleet, selfID: context.selfID) {
        case .success(let found):
            id = found
        case .failure(.notFound) where condition == "gone" && UUID(uuidString: token) != nil:
            // Only a full id may be already gone: a mistyped title would otherwise "succeed".
            out("{}")
            return finish(0)
        case .failure(let error):
            return resolveFailed(error, "session")
        }
        let evaluate = {
            let current = self.session(id)
            if condition == "gone" {
                if current == nil { self.out("{}"); self.finish(0) }
                return
            }
            // A closed tab can never reach any activity, so waiting on would hang to the timeout.
            guard let current else { return self.fail("gone") }
            if current.activity == condition { self.out(CLIOutput.json(current)); self.finish(0) }
        }
        onEvent = { _ in evaluate() }
        onSnapshot = { _ in evaluate() }
        evaluate()
    }

    /// `send --wait`. A bare `wait --for idle` straight after `send` returns at once: the ack
    /// means the Mac took the text, not that the agent has started, so the tab is still idle.
    /// This waits for three things in order instead, each keyed so nothing earlier or
    /// unrelated can satisfy it:
    ///
    /// 1. `promptTyped` with **our** token — the Mac actually typed the text (it may queue it
    ///    behind a busy composer first). Registered before the send, because the Mac can type
    ///    and emit before the ack is written.
    /// 2. A non-idle `activityChanged` after that — the turn began. An idle arriving before it
    ///    is the old state still settling, not the turn's end.
    /// 3. The next `idle` or `waiting` — the turn ended, or it needs a human.
    private func sendAndWait(_ token: String, _ text: String) {
        guard let id = sessionID(token) else { return }
        let promptToken = UUID()
        var typed = false
        var started = false
        onEvent = { event in
            switch event {
            case .promptTyped(id, promptToken):
                typed = true
            case .promptExpired(id, promptToken):
                // Dropped from the Mac's bounded queue: the text will never be typed.
                self.fail("prompt_expired")
            case .sessionRemoved(id):
                self.fail("gone")
            case .activityChanged(id, let activity, _, _, _, _, _) where typed:
                guard started else { started = activity != nil && activity != "idle"; return }
                guard activity == "idle" || activity == "waiting", let current = self.session(id) else { return }
                self.out(CLIOutput.json(current))
                self.finish(0)
            default:
                break
            }
        }
        // A reset snapshot carries no removal event; a tab absent from it is gone all the same.
        onSnapshot = { _ in if self.session(id) == nil { self.fail("gone") } }
        let cid = transport.send(.prompt(id: id, token: promptToken, text: text))
        replies[cid] = { frame in
            if case .err(_, let code) = frame { self.fail(code) }
        }
    }

    /// With `--agent`, the row is checked against the project's own menu first: FleetService
    /// reads an agent/account it cannot match as a plain `+`, so an unchecked typo would open
    /// the project's default agent and exit 0 as if it had worked.
    private func new(_ token: String, agent: String?, account: Int?) {
        guard let projectID = project(token) else { return }
        guard let agent, let account else { return launch(projectID, agent: nil, account: nil) }
        let cid = transport.send(.newSessionOptions(project: projectID))
        replies[cid] = { frame in
            guard case .newSessionOptions(_, let menu) = frame else {
                if case .err(_, let code) = frame { return self.fail(code) }
                return self.fail("unexpected_reply")
            }
            guard menu.options.contains(where: { $0.agent == agent && $0.index == account }) else {
                let rows = menu.options.map { "  \($0.agent) \($0.index)" + ($0.accountName.map { "  \($0)" } ?? "") }
                return self.usage((["no such agent/account for this project: \(agent) \(account); available:"]
                                   + (rows.isEmpty ? ["  (none)"] : rows)).joined(separator: "\n"))
            }
            self.launch(projectID, agent: agent, account: account)
        }
    }

    private func launch(_ projectID: UUID, agent: String?, account: Int?) {
        // Two facts, in either order: the ack (the Mac took it) and the tab itself. The event
        // may beat the ack onto the wire, so neither is assumed to come first.
        var acked = false
        var added: WireSession?
        let settle = {
            guard acked, let added else { return }
            self.out(self.wantsJSON ? CLIOutput.json(added) : added.id.uuidString)
            self.finish(0)
        }
        onEvent = { event in
            // Only a tab in the project asked for: another client's `new` elsewhere is not ours.
            guard added == nil, case .sessionAdded(let session, projectID, _) = event else { return }
            added = session
            settle()
        }
        let cid = transport.send(.newSession(project: projectID, agent: agent, accountIndex: account))
        replies[cid] = { frame in
            if case .err(_, let code) = frame { return self.fail(code) }
            acked = true
            settle()
        }
        schedule(Self.launchTimeout) { self.fail("launch_unconfirmed") }
    }

    /// Fetches the latest page and derives the open prompt from it exactly as the phone does —
    /// the prompt is never on the wire, so this is the only way to know what is being asked.
    private func derivePrompt(_ token: String, then: @escaping (WireSession, OpenPrompt) -> Void) {
        guard let resolved = session(token) else { return }
        let cid = transport.send(.timeline(session: resolved.id, anchor: .latest,
                                           limit: TimelineLimits.maxLimit))
        replies[cid] = { frame in
            guard case .page(_, let page) = frame else {
                if case .err(_, let code) = frame { return self.fail(code) }
                return self.fail("unexpected_reply")
            }
            // The fleet as of the page, not the request: the session may have left `waiting`.
            let current = self.session(resolved.id) ?? resolved
            guard let prompt = OpenPrompt.find(in: page.items, agent: current.agent,
                                               activity: current.activity)
            else { return self.fail("no_prompt") }
            then(current, prompt)
        }
    }

    private func answer(_ prompt: OpenPrompt, session: UUID, choice: CLIAnswerChoice, call: String?) {
        let answer: PromptAnswer
        switch (choice, prompt) {
        case (.allow, .permission): answer = .allow
        case (.deny, .permission): answer = .deny
        case (.allow, .question), (.deny, .question):
            return usage("answer: this is a question — answer with [[index…]] (see flightdeck prompt)")
        case (.selections, .permission):
            return usage("answer: this is a permission prompt — answer with allow or deny")
        case (.selections(let selections), .question(_, let questions)):
            // Checked here, before anything is sent: the Mac would refuse a bad index too, but
            // only after a round trip, and a set is answered as a unit so a short one is never
            // a partial answer worth sending.
            guard selections.count == questions.count else {
                return usage("answer: the prompt asks \(questions.count) question(s), got \(selections.count)")
            }
            for (q, picks) in selections.enumerated() {
                let options = questions[q].options
                for pick in picks where !options.indices.contains(pick) {
                    return usage("answer: question \(q) has no option \(pick) (0–\(options.count - 1))")
                }
            }
            answer = .answers(selections.enumerated().map { q, picks in
                picks.map { AnswerSelection(index: $0, label: questions[q].options[$0].label) }
            })
        }
        send(.answerPrompt(id: session, token: UUID(), call: call ?? prompt.callID, answer: answer))
    }

    private func plan(_ token: String, _ make: (UUID, String) -> FleetCommand) {
        guard let resolved = session(token) else { return }
        guard let call = resolved.planGate?.callID else { return fail("no_plan_gate") }
        send(make(resolved.id, call))
    }

    private func raw() {
        guard let frame = rawFrame else { return }
        transport.send(raw: frame)
        switch frame {
        case .hello:
            onSnapshot = { snapshot in self.out(CLIOutput.line(snapshot)); self.finish(0) }
        case .cmd(let cid, _), .req(let cid, _):
            replies[cid] = { reply in
                self.out(CLIOutput.line(reply))
                if case .err = reply { return self.finish(1) }
                self.finish(0)
            }
        case .logs, .refused:
            // Answers to a question the Mac asked; nothing comes back for them.
            finish(0)
        }
    }

    // MARK: Plumbing

    private func command(on token: String, _ make: (UUID) -> FleetCommand) {
        guard let id = sessionID(token) else { return }
        send(make(id))
    }

    /// `ack` means dispatched, not done — the effect arrives later as an event — so exit 0 says
    /// only that the Mac accepted the command.
    private func send(_ command: FleetCommand) {
        let cid = transport.send(command)
        replies[cid] = { frame in
            if case .err(_, let code) = frame { return self.fail(code) }
            self.finish(0)
        }
    }

    private func request(_ request: FleetRequest) {
        let cid = transport.send(request)
        replies[cid] = { frame in
            // No `default`: a new reply case must be given an output before this compiles.
            switch frame {
            case .err(_, let code): return self.fail(code)
            case .page(_, let page): self.out(CLIOutput.json(page))
            case .newSessionOptions(_, let options): self.out(CLIOutput.json(options))
            case .macEndpoints(_, let endpoints): self.out(CLIOutput.json(endpoints))
            case .recentlyClosed(_, let closed): self.out(CLIOutput.json(closed))
            case .conversations(_, let catalogue): self.out(CLIOutput.json(catalogue))
            case .searchHits(_, let hits): self.out(CLIOutput.json(hits))
            case .session(_, let id): self.out(id.uuidString)
            case .ack, .snapshot, .event, .phoneRequest: self.out(CLIOutput.line(frame))
            }
            self.finish(0)
        }
    }

    private func sessionID(_ token: String) -> UUID? {
        switch CLISessionResolver.session(token, in: fleet, selfID: context.selfID) {
        case .success(let id): return id
        case .failure(let error): resolveFailed(error, "session"); return nil
        }
    }

    /// A resolved session that must also be in the fleet — for the commands that read its state.
    private func session(_ token: String) -> WireSession? {
        guard let id = sessionID(token) else { return nil }
        guard let found = session(id) else { resolveFailed(.notFound(token), "session"); return nil }
        return found
    }

    private func session(_ id: UUID) -> WireSession? {
        fleet.projects.lazy.flatMap(\.sessions).first { $0.id == id }
    }

    private func project(_ token: String) -> UUID? {
        switch CLISessionResolver.project(token, in: fleet, cwd: context.cwd) {
        case .success(let id): return id
        case .failure(let error): resolveFailed(error, "project"); return nil
        }
    }

    /// Exit 2, naming every candidate: nothing is acted on by guess, and the full ids are what
    /// the caller needs to retry unambiguously.
    private func resolveFailed(_ error: CLIResolveError, _ kind: String) {
        switch error {
        case .noSelf:
            usage("\"self\" needs FLIGHT_DECK_SESSION_ID — run inside a Flight Deck tab")
        case .notFound(let token):
            usage("no \(kind) matches \"\(token)\"")
        case .ambiguous(let token, let ids):
            let names = Dictionary(
                fleet.projects.map { ($0.id, $0.name) } + fleet.projects.flatMap(\.sessions).map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first })
            let candidates = ids.map { "  \($0.uuidString)  \(names[$0] ?? "")" }
            usage((["\"\(token)\" matches \(ids.count) \(kind)s:"] + candidates).joined(separator: "\n"))
        }
    }

    private func usage(_ message: String) {
        guard !finished else { return }
        err("flightdeck: \(message)")
        finish(2)
    }

    /// A machine-readable code, bare, on stderr — the wire's own `err` code or one of the CLI's
    /// (`no_prompt`, `timed_out`, …), so a script can match on it.
    private func fail(_ code: String) {
        // A timeout firing after the answer must not print a stray code.
        guard !finished else { return }
        err(code)
        finish(1)
    }

    private func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        onFinish(code)
    }
}
