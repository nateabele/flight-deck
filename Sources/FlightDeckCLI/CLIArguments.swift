import FleetKit
import Foundation

/// A `flightdeck` invocation could not be parsed. The message names the specific problem
/// (an unknown verb, a missing operand, an unrecognised flag, a malformed number) so the CLI
/// can print it verbatim rather than a generic "bad arguments".
public struct CLIUsageError: Error, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// What `answer` is telling the Mac to do with an open permission dialog.
public enum CLIAnswerChoice: Equatable {
    /// The parsed `[[Int]]` a multi-select dialog's answer channel takes — one array of
    /// chosen indices per question.
    case selections([[Int]])
    case allow
    case deny
}

/// Every shape a `flightdeck` invocation can take, already validated — a `CLICommand` is
/// always ready to execute, never a partial parse that still needs checking.
public enum CLICommand: Equatable {
    case help
    case ls(project: String?)
    case tail(session: String?, since: Int?, noSnapshot: Bool)
    case wait(session: String, condition: String, timeout: TimeInterval?)
    /// `wait`: after the ack, block until the turn this text started has ended — see
    /// `CLIRunner.sendAndWait` for why a bare `wait` after `send` cannot do that.
    case send(session: String, text: String, wait: Bool = false, timeout: TimeInterval? = nil)
    case new(project: String, agent: String?, account: Int?)
    case close(String)
    case reopen(UUID)
    case rename(String, title: String)
    case read(String)
    case unread(String)
    case collapse(project: String, collapsed: Bool)
    case prompt(session: String)
    case answer(session: String, choice: CLIAnswerChoice, call: String?)
    case abort(session: String)
    case planResolve(session: String, approve: Bool, feedback: String?)
    case planAnnotate(session: String, text: String, block: Int?)
    case timeline(session: String, anchor: TimelineAnchor, limit: Int)
    case search(query: String, limit: Int)
    case open(conversation: String, projectPath: String)
    case closed
    case options(project: String)
    case raw(String)
}

/// A fully parsed command line: the command itself, plus the two globals (`--json`,
/// `--socket`) that may appear anywhere among the verb's own arguments — anywhere before a
/// `--`, past which every argument is an operand.
public struct CLIInvocation: Equatable {
    public var command: CLICommand
    public var json: Bool
    public var socket: String?

    public init(command: CLICommand, json: Bool = false, socket: String? = nil) {
        self.command = command
        self.json = json
        self.socket = socket
    }
}

/// Hand-rolled on purpose — see the brief: no package dependency for a parser this small.
public enum CLIArguments {
    /// `timeline`'s default page size absent `--limit`.
    private static let defaultTimelineLimit = 40
    /// `search`'s default hit count absent `--limit`.
    private static let defaultSearchLimit = 20
    /// What `wait --for` can wait on: `SessionActivity`'s raw values, plus `gone`. Anything
    /// else can never hold, so a typo like `idel` would wait silently until its timeout.
    private static let waitConditions: Set<String> = ["idle", "busy", "waiting", "gone"]

    /// - Parameter args: argv with argv[0] already stripped.
    public static func parse(_ args: [String]) throws -> CLIInvocation {
        if args.isEmpty { return CLIInvocation(command: .help) }

        // Globals may appear anywhere, so they're stripped in a first pass rather than
        // threaded through every verb's own cursor — each verb below sees only its operands.
        // Stripping from every position is also what would eat `send S --json` as a flag, so
        // `--` ends it: everything after is kept verbatim and never read as a flag.
        var json = false
        var socket: String?
        var rest: [String] = []
        var literalFrom: Int?
        var cursor = Cursor(args)
        while let token = cursor.next() {
            switch token {
            case "--":
                literalFrom = rest.count
                while let literal = cursor.next() { rest.append(literal) }
            case "--json": json = true
            case "--socket":
                guard let value = cursor.next() else {
                    throw CLIUsageError("--socket requires a value")
                }
                socket = value
            default: rest.append(token)
            }
        }

        if rest.isEmpty || (literalFrom != 0 && ["help", "-h", "--help"].contains(rest[0])) {
            return CLIInvocation(command: .help, json: json, socket: socket)
        }

        let verb = rest[0]
        var body = Cursor(Array(rest.dropFirst()), literalFrom: literalFrom.map { max(0, $0 - 1) })
        let command = try parseVerb(verb, &body)
        // One check for every verb: an operand nothing consumed is refused by name. Dropping
        // it is how `open CONVO --project PATH` once sent the literal "--project" as a path.
        try body.end()
        return CLIInvocation(command: command, json: json, socket: socket)
    }

    private static func parseVerb(_ verb: String, _ c: inout Cursor) throws -> CLICommand {
        switch verb {
        case "ls":
            return .ls(project: try c.optionalPositionalOrFlag("--project"))

        case "tail":
            var session: String?
            var since: Int?
            var noSnapshot = false
            while let flag = c.nextFlag() {
                switch flag {
                case "--session": session = try c.require(after: flag)
                case "--since": since = try c.int(after: flag)
                case "--no-snapshot": noSnapshot = true
                default: throw CLIUsageError("tail: unknown flag \"\(flag)\"")
                }
            }
            return .tail(session: session, since: since, noSnapshot: noSnapshot)

        case "wait":
            let session = try c.requirePositional("wait: missing session")
            var condition: String?
            var timeout: TimeInterval?
            while let flag = c.nextFlag() {
                switch flag {
                case "--for": condition = try c.require(after: flag)
                case "--timeout": timeout = TimeInterval(try c.int(after: flag))
                default: throw CLIUsageError("wait: unknown flag \"\(flag)\"")
                }
            }
            guard let condition else { throw CLIUsageError("wait: --for is required") }
            guard waitConditions.contains(condition) else {
                throw CLIUsageError("wait: --for must be idle, busy, waiting or gone, got \"\(condition)\"")
            }
            return .wait(session: session, condition: condition, timeout: timeout)

        case "send":
            let session = try c.requirePositional("send: missing session")
            let text = try c.requirePositional("send: missing text")
            var wait = false
            var timeout: TimeInterval?
            while let flag = c.nextFlag() {
                switch flag {
                case "--wait": wait = true
                case "--timeout": timeout = TimeInterval(try c.int(after: flag))
                default: throw CLIUsageError("send: unknown flag \"\(flag)\"")
                }
            }
            // Refused rather than ignored: without `--wait` there is nothing for it to bound,
            // and a script that set it believes it is waiting.
            if timeout != nil, !wait { throw CLIUsageError("send: --timeout needs --wait") }
            return .send(session: session, text: text, wait: wait, timeout: timeout)

        case "new":
            let project = try c.requirePositional("new: missing project")
            var agent: String?
            var account: Int?
            while let flag = c.nextFlag() {
                switch flag {
                case "--agent": agent = try c.require(after: flag)
                case "--account": account = try c.int(after: flag)
                default: throw CLIUsageError("new: unknown flag \"\(flag)\"")
                }
            }
            // FleetService reads a nil on either side as a plain `+`, so an account with no
            // agent would silently open the project's default agent instead.
            if account != nil, agent == nil { throw CLIUsageError("new: --account needs --agent") }
            // An agent alone means its first account — the row a flat menu entry stands for.
            return .new(project: project, agent: agent, account: agent == nil ? nil : account ?? 0)

        case "close":
            return .close(try c.requirePositional("close: missing session"))

        case "reopen":
            let token = try c.requirePositional("reopen: missing session")
            guard let id = UUID(uuidString: token) else {
                throw CLIUsageError("reopen: requires a full UUID, got \"\(token)\"")
            }
            return .reopen(id)

        case "rename":
            let session = try c.requirePositional("rename: missing session")
            let title = try c.requirePositional("rename: missing title")
            return .rename(session, title: title)

        case "read":
            return .read(try c.requirePositional("read: missing session"))

        case "unread":
            return .unread(try c.requirePositional("unread: missing session"))

        case "collapse":
            let project = try c.requirePositional("collapse: missing project")
            var collapsed = true
            while let flag = c.nextFlag() {
                switch flag {
                case "--off": collapsed = false
                default: throw CLIUsageError("collapse: unknown flag \"\(flag)\"")
                }
            }
            return .collapse(project: project, collapsed: collapsed)

        case "prompt":
            return .prompt(session: try c.requirePositional("prompt: missing session"))

        case "answer":
            let session = try c.requirePositional("answer: missing session")
            let token = try c.requirePositional("answer: missing choice")
            let choice = try parseAnswerChoice(token)
            var call: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--call": call = try c.require(after: flag)
                default: throw CLIUsageError("answer: unknown flag \"\(flag)\"")
                }
            }
            return .answer(session: session, choice: choice, call: call)

        case "abort":
            return .abort(session: try c.requirePositional("abort: missing session"))

        case "plan":
            return try parsePlan(&c)

        case "timeline":
            let session = try c.requirePositional("timeline: missing session")
            var anchor = TimelineAnchor.latest
            var limit = defaultTimelineLimit
            while let flag = c.nextFlag() {
                switch flag {
                case "--before": anchor = .before(try c.int(after: flag))
                case "--after": anchor = .after(try c.int(after: flag))
                case "--around": anchor = .around(try c.int(after: flag))
                case "--limit": limit = try c.int(after: flag)
                default: throw CLIUsageError("timeline: unknown flag \"\(flag)\"")
                }
            }
            return .timeline(session: session, anchor: anchor, limit: limit)

        case "search":
            let query = try c.requirePositional("search: missing query")
            var limit = defaultSearchLimit
            while let flag = c.nextFlag() {
                switch flag {
                case "--limit": limit = try c.int(after: flag)
                default: throw CLIUsageError("search: unknown flag \"\(flag)\"")
                }
            }
            return .search(query: query, limit: limit)

        case "open":
            let conversation = try c.requirePositional("open: missing conversation")
            var projectPath: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--project": projectPath = try c.require(after: flag)
                default: throw CLIUsageError("open: unknown flag \"\(flag)\"")
                }
            }
            guard let projectPath else { throw CLIUsageError("open: --project PATH is required") }
            return .open(conversation: conversation, projectPath: projectPath)

        case "closed":
            return .closed

        case "options":
            return .options(project: try c.requirePositional("options: missing project"))

        case "raw":
            return .raw(try c.requirePositional("raw: missing command"))

        default:
            throw CLIUsageError("unknown command \"\(verb)\"")
        }
    }

    private static func parsePlan(_ c: inout Cursor) throws -> CLICommand {
        let sub = try c.requirePositional("plan: missing subcommand")
        switch sub {
        case "approve", "reject":
            let session = try c.requirePositional("plan \(sub): missing session")
            var feedback: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--feedback": feedback = try c.require(after: flag)
                default: throw CLIUsageError("plan \(sub): unknown flag \"\(flag)\"")
                }
            }
            return .planResolve(session: session, approve: sub == "approve", feedback: feedback)

        case "annotate":
            let session = try c.requirePositional("plan annotate: missing session")
            let text = try c.requirePositional("plan annotate: missing text")
            var block: Int?
            while let flag = c.nextFlag() {
                switch flag {
                case "--block": block = try c.int(after: flag)
                default: throw CLIUsageError("plan annotate: unknown flag \"\(flag)\"")
                }
            }
            return .planAnnotate(session: session, text: text, block: block)

        default:
            throw CLIUsageError("plan: unknown subcommand \"\(sub)\"")
        }
    }

    /// `allow`, `deny`, or a JSON `[[Int]]` — the shape a multi-select dialog's answer takes.
    private static func parseAnswerChoice(_ token: String) throws -> CLIAnswerChoice {
        switch token {
        case "allow": return .allow
        case "deny": return .deny
        default:
            guard let data = token.data(using: .utf8),
                  let selections = try? JSONDecoder().decode([[Int]].self, from: data)
            else {
                throw CLIUsageError("answer: choice must be \"allow\", \"deny\" or a JSON [[Int]], got \"\(token)\"")
            }
            return .selections(selections)
        }
    }

    /// A single left-to-right walk over one verb's own tokens, past the globals pass. Every
    /// verb reads flags in whatever order it likes via `next()`/`flag`/`int`, rather than each
    /// hand-rolling its own index bookkeeping.
    private struct Cursor {
        private var tokens: [String]
        private var index = 0
        /// Where a `--` ended options: tokens from here on are operands, never flags.
        private let literalFrom: Int

        init(_ tokens: [String], literalFrom: Int? = nil) {
            self.tokens = tokens
            self.literalFrom = literalFrom ?? tokens.count
        }

        /// The next token if it is a flag — dash-led and before any `--` — for a verb's flag
        /// loop. Anything else is left in place, for `end()` to refuse by name rather than
        /// have the loop call an operand an "unknown flag".
        mutating func nextFlag() -> String? {
            guard index < tokens.count, index < literalFrom, tokens[index].hasPrefix("-") else { return nil }
            return next()
        }

        /// Every token consumed. Called once, after the verb has read all it takes.
        func end() throws {
            guard index < tokens.count else { return }
            throw CLIUsageError("unexpected argument \"\(tokens[index])\"")
        }

        mutating func next() -> String? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        /// The next token, required to exist — for a flag's own value, named after the flag
        /// that demanded it so the error names the actual problem.
        mutating func require(after flag: String) throws -> String {
            guard let value = next() else { throw CLIUsageError("\(flag) requires a value") }
            return value
        }

        mutating func int(after flag: String) throws -> Int {
            let raw = try require(after: flag)
            guard let value = Int(raw) else { throw CLIUsageError("\(flag) expects a number, got \"\(raw)\"") }
            return value
        }

        /// The next token as a required positional, with a caller-supplied message — used for
        /// a verb's own leading operands (session, project, text, …), never for a flag's value.
        ///
        /// A dash-led token before any `--` is refused, not taken: `send S --wait` would
        /// otherwise type the literal "--wait" into the agent and never wait. Text that really
        /// starts with a dash goes after `--`.
        mutating func requirePositional(_ message: String) throws -> String {
            guard index < tokens.count else { throw CLIUsageError(message) }
            let value = tokens[index]
            if index < literalFrom, value.count > 1, value.hasPrefix("-") {
                throw CLIUsageError("\(message) (got flag \"\(value)\" — put -- before an operand that starts with -)")
            }
            index += 1
            return value
        }

        /// `ls [project]` / `ls --project P`: the one place a bare positional and a named flag
        /// are both accepted for the same operand, and both are optional.
        mutating func optionalPositionalOrFlag(_ flagName: String) throws -> String? {
            guard let token = next() else { return nil }
            if token == flagName { return try require(after: flagName) }
            return token
        }
    }
}
