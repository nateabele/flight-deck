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
    /// `main.swift` intercepts this before the runner even exists — see its comment — so
    /// `CLIRunner` never sees one dispatched. Parsed here anyway because argument validation
    /// (a real UUID, `--root` present) belongs with every other verb's, not duplicated in main.
    case intakeRun(id: UUID, root: String)
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
        var cursor = args.makeIterator()
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
        try body.end(verb: verb)
        return CLIInvocation(command: command, json: json, socket: socket)
    }

    private static func parseVerb(_ verb: String, _ c: inout Cursor) throws -> CLICommand {
        switch verb {
        case "ls":
            // `ls P` and `ls --project P` both name the project; giving it twice is an error.
            var project = c.optionalPositional()
            while let flag = c.nextFlag() {
                switch flag {
                case "--project":
                    guard project == nil else { throw CLIUsageError("ls: project given twice") }
                    project = try c.require(after: flag)
                default: throw Cursor.unknownFlag(flag, in: "ls")
                }
            }
            return .ls(project: project)

        case "tail":
            var session: String?
            var since: Int?
            var noSnapshot = false
            while let flag = c.nextFlag() {
                switch flag {
                case "--session": session = try c.require(after: flag)
                case "--since": since = try c.int(after: flag)
                case "--no-snapshot": noSnapshot = true
                default: throw Cursor.unknownFlag(flag, in: "tail")
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
                default: throw Cursor.unknownFlag(flag, in: "wait")
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
                default: throw Cursor.unknownFlag(flag, in: "send")
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
                default: throw Cursor.unknownFlag(flag, in: "new")
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
                default: throw Cursor.unknownFlag(flag, in: "collapse")
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
                default: throw Cursor.unknownFlag(flag, in: "answer")
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
                default: throw Cursor.unknownFlag(flag, in: "timeline")
                }
            }
            return .timeline(session: session, anchor: anchor, limit: limit)

        case "search":
            let query = try c.requirePositional("search: missing query")
            var limit = defaultSearchLimit
            while let flag = c.nextFlag() {
                switch flag {
                case "--limit": limit = try c.int(after: flag)
                default: throw Cursor.unknownFlag(flag, in: "search")
                }
            }
            return .search(query: query, limit: limit)

        case "open":
            let conversation = try c.requirePositional("open: missing conversation")
            var projectPath: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--project": projectPath = try c.require(after: flag)
                default: throw Cursor.unknownFlag(flag, in: "open")
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

        case "intake":
            return try parseIntake(&c)

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
                default: throw Cursor.unknownFlag(flag, in: "plan \(sub)")
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
                default: throw Cursor.unknownFlag(flag, in: "plan annotate")
                }
            }
            return .planAnnotate(session: session, text: text, block: block)

        default:
            throw CLIUsageError("plan: unknown subcommand \"\(sub)\"")
        }
    }

    private static func parseIntake(_ c: inout Cursor) throws -> CLICommand {
        let sub = try c.requirePositional("intake: missing subcommand")
        switch sub {
        case "run":
            let token = try c.requirePositional("intake run: missing id")
            guard let id = UUID(uuidString: token) else {
                throw CLIUsageError("intake run: requires a full UUID, got \"\(token)\"")
            }
            var root: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--root": root = try c.require(after: flag)
                default: throw Cursor.unknownFlag(flag, in: "intake run")
                }
            }
            guard let root else { throw CLIUsageError("intake run: --root DIR is required") }
            return .intakeRun(id: id, root: root)

        default:
            throw CLIUsageError("intake: unknown subcommand \"\(sub)\"")
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

    /// Every flag, across all verbs, that takes a value. The partition in `Cursor` needs it to
    /// know that `--before -1`'s `-1` is a value, not a flag of its own; a value flag a verb
    /// does not know still reaches that verb's loop and is refused there by name.
    private static let valueFlags: Set<String> = [
        "--session", "--since", "--for", "--timeout", "--agent", "--account", "--call",
        "--before", "--after", "--around", "--limit", "--project", "--feedback", "--block",
        "--root",
    ]

    /// One verb's tokens, split up front into two streams: operands (session, text, …) and
    /// flags with their values. Split rather than walked left to right so a verb's flags may
    /// sit before or after its operands — `send S --wait -- "- text"` and `send S "text"
    /// --wait` both parse — and every verb reads each stream in whatever order it likes.
    ///
    /// Before a `--`, every dash-led token (other than a bare `-`) is a flag, so an unknown
    /// one is refused by the verb rather than typed into an agent as text. After `--`,
    /// nothing is a flag and nothing is a flag's value.
    private struct Cursor {
        private var operands: [String] = []
        private var flags: [String] = []
        private var operandIndex = 0
        private var flagIndex = 0

        init(_ tokens: [String], literalFrom: Int? = nil) {
            let boundary = literalFrom ?? tokens.count
            var i = 0
            while i < tokens.count {
                let token = tokens[i]
                if i < boundary, token.count > 1, token.hasPrefix("-") {
                    flags.append(token)
                    // A value is taken only from before `--`: `--limit -- 5` has no value.
                    if CLIArguments.valueFlags.contains(token), i + 1 < boundary {
                        flags.append(tokens[i + 1])
                        i += 1
                    }
                } else {
                    operands.append(token)
                }
                i += 1
            }
        }

        /// The error for a flag the verb does not take, naming the form that does work for the
        /// most likely cause: text that starts with a dash, which belongs after `--`.
        static func unknownFlag(_ flag: String, in verb: String) -> CLIUsageError {
            CLIUsageError("\(verb): unknown flag \"\(flag)\" (an operand that starts with - goes after --, e.g. flightdeck send S --wait -- \"- text\")")
        }

        /// The next flag, for a verb's flag loop; its value, if it takes one, is read next
        /// with `require(after:)`/`int(after:)`.
        mutating func nextFlag() -> String? {
            guard flagIndex < flags.count else { return nil }
            defer { flagIndex += 1 }
            return flags[flagIndex]
        }

        /// Every token consumed. Called once, after the verb has read all it takes: a verb with
        /// no flag loop leaves any flag here, and an operand nothing asked for is refused by
        /// name rather than dropped.
        ///
        /// Named for `verb`, like every other usage error: main.swift already prints
        /// "flightdeck: " in front, so naming the program here would print it twice.
        func end(verb: String) throws {
            if flagIndex < flags.count { throw Cursor.unknownFlag(flags[flagIndex], in: verb) }
            guard operandIndex < operands.count else { return }
            throw CLIUsageError("unexpected argument \"\(operands[operandIndex])\"")
        }

        /// A flag's own value — the partition placed it right after the flag. Named after the
        /// flag that demanded it so the error names the actual problem.
        mutating func require(after flag: String) throws -> String {
            // A value flag with no value left nothing behind it; a bare flag never has one.
            guard CLIArguments.valueFlags.contains(flag), let value = nextFlag() else {
                throw CLIUsageError("\(flag) requires a value")
            }
            return value
        }

        mutating func int(after flag: String) throws -> Int {
            let raw = try require(after: flag)
            guard let value = Int(raw) else { throw CLIUsageError("\(flag) expects a number, got \"\(raw)\"") }
            return value
        }

        /// The next operand, required, with a caller-supplied message. When it is missing but a
        /// flag is still unread, the likeliest cause is text that starts with a dash (`send S
        /// -x`), which was taken as a flag — so the error says where such text goes.
        mutating func requirePositional(_ message: String) throws -> String {
            guard let value = optionalPositional() else {
                guard flagIndex < flags.count else { throw CLIUsageError(message) }
                throw CLIUsageError("\(message) — \"\(flags[flagIndex])\" was read as a flag (an operand that starts with - goes after --, e.g. flightdeck send S --wait -- \"- text\")")
            }
            return value
        }

        mutating func optionalPositional() -> String? {
            guard operandIndex < operands.count else { return nil }
            defer { operandIndex += 1 }
            return operands[operandIndex]
        }
    }
}
