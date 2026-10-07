import Foundation

/// What a seat is doing right now, as a verb and its object: "Reading" `Sources/App.swift`,
/// "Searching" `"func run"`, "Running" `git log -8`. `object` is a project-relative path when
/// the thing touched lies inside the project and an absolute one otherwise — the UI
/// middle-truncates it, so this never shortens it itself.
public struct ActivityAction: Codable, Equatable, Sendable {
    public var verb: String
    public var object: String?
    public init(verb: String, object: String?) { self.verb = verb; self.object = object }
}

/// The agent's own checklist, when it keeps one (codex `todo_list`, claude `TodoWrite`).
/// `current` is the item in progress, or the first one not yet done.
public struct ActivitySteps: Codable, Equatable, Sendable {
    public var done: Int, total: Int
    public var current: String?
    public init(done: Int, total: Int, current: String?) { self.done = done; self.total = total; self.current = current }
}

/// One seat's live activity, folded from the harness's own stream by `ActivityParser` and
/// published as `runs/<run>/activity.json` (rounds) or `triage/activity.json` (triage) — so
/// the app draws it without ever parsing a stream itself. Built ONLY from signals the agents
/// really emit: neither harness reports a percentage or an ETA, so there are none here, and
/// `costUSD` exists only because claude's final `result` states one (codex never does).
public struct SeatActivity: Codable, Equatable, Sendable {
    public var harness: Harness
    /// The latest reasoning (codex) or thinking (claude) summary: its first sentence, markdown
    /// bold stripped, at most `ActivityParser.headlineLimit` characters.
    public var headline: String?
    public var action: ActivityAction?
    /// Distinct files read or edited, counted per top-level directory relative to the project
    /// (`.` for files at the project root). A file outside the project counts under its own
    /// parent directory's name, or `other` when it has none.
    public var footprint: [String: Int] = [:]
    public var steps: ActivitySteps?
    /// Cumulative for this run. Input includes cached input — it is what the model processed.
    public var inputTokens: Int?, outputTokens: Int?
    /// When claude last reported a rejecting `rate_limit_event`; cleared by the next assistant
    /// event, since the model speaking again is the only proof the limit lifted.
    public var rateLimitedAt: Date?
    /// The windows claude's last `rate_limit_event` reported (`unifiedWindows`). claude sends one
    /// per API call, allowed or not, so a headless seat meters the account it runs on for free
    /// (Flight Control L3-U). Nil until the first event carrying windows; an event without
    /// windows leaves the last ones standing.
    public var rateLimitWindows: [UsageWindow]?
    /// That event's `status` — `allowed`, `allowed_warning`, `rejected` — verbatim.
    public var rateLimitStatus: String?
    /// That event's top-level `resetsAt`: when a rejection lifts.
    public var rateLimitResetsAt: Date?
    public var startedAt: Date
    public var lastEventAt: Date?
    /// claude's final `result.total_cost_usd`; codex reports none.
    public var costUSD: Double?
    public var finished = false
    public var error: String?
    public init(harness: Harness, startedAt: Date) { self.harness = harness; self.startedAt = startedAt }
}

/// What one seat produced, written to `runs/<run>/result.json` the moment that seat's own
/// structured output parses — so its row can say what it did while the rest of the round is
/// still running, instead of waiting for the whole round's `RoundRecord` (which lands only
/// with the checkpoint, by which time the app has stopped following the round's seats).
/// Every field but `kind` is filled only by the seats it describes, and is optional on disk.
public struct SeatResult: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A reviewer or synthesizer: `changeCount` proposals touching `sections`.
        case reviewer
        /// `agree`/`somewhat`/`disagree` plus the plan delta it actually made
        /// (`linesAdded`/`linesRemoved` across `sections`).
        case integrator
        /// An encoder, polisher, fresh-eyes or dedup seat: `ops`, counted as its checkpoint's
        /// `changeCount` is.
        case changeSet
        /// A drafter: the draft's length, in `linesAdded` (a draft is written from nothing).
        case draft
    }
    public var kind: Kind
    public var changeCount: Int?
    public var sections: [String]
    public var agree: Int?, somewhat: Int?, disagree: Int?
    public var linesAdded: Int?, linesRemoved: Int?
    public var ops: Int?

    public init(kind: Kind, changeCount: Int? = nil, sections: [String] = [], agree: Int? = nil, somewhat: Int? = nil,
                disagree: Int? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil, ops: Int? = nil) {
        self.kind = kind; self.changeCount = changeCount; self.sections = sections
        self.agree = agree; self.somewhat = somewhat; self.disagree = disagree
        self.linesAdded = linesAdded; self.linesRemoved = linesRemoved; self.ops = ops
    }

    private enum CodingKeys: String, CodingKey {
        case kind, changeCount, sections, agree, somewhat, disagree, linesAdded, linesRemoved, ops
    }

    /// `sections` may be absent on disk too — a change-set or draft result has none to write.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        changeCount = try c.decodeIfPresent(Int.self, forKey: .changeCount)
        sections = try c.decodeIfPresent([String].self, forKey: .sections) ?? []
        agree = try c.decodeIfPresent(Int.self, forKey: .agree)
        somewhat = try c.decodeIfPresent(Int.self, forKey: .somewhat)
        disagree = try c.decodeIfPresent(Int.self, forKey: .disagree)
        linesAdded = try c.decodeIfPresent(Int.self, forKey: .linesAdded)
        linesRemoved = try c.decodeIfPresent(Int.self, forKey: .linesRemoved)
        ops = try c.decodeIfPresent(Int.self, forKey: .ops)
    }
}

/// An incremental fold from one harness's stream (`codex exec --json` or `claude -p
/// --output-format stream-json --verbose`) into a `SeatActivity`. `feed` takes raw chunks as
/// a pipe hands them over — a line split across chunks is buffered until its newline — and
/// anything that isn't a JSON object is skipped without touching the activity, so a torn line
/// or a stray banner can never break or blank a seat's row.
public struct ActivityParser: Sendable {
    public static let headlineLimit = 90

    public private(set) var activity: SeatActivity
    private let project: URL
    private let cwd: URL
    private let now: @Sendable () -> Date
    private var pending = Data()
    private var touched: Set<String> = []
    /// claude repeats a message's usage on every content block it streams, so usage is kept
    /// per message id and summed — adding each event's would count a message several times.
    private var claudeUsage: [String: (input: Int, output: Int)] = [:]
    private var codexTurns: (input: Int, output: Int) = (0, 0)
    /// agy streams its answer as `text_delta`s; the headline is the first sentence of the
    /// response so far, so the deltas are joined before it is cut.
    private var geminiResponse = ""

    /// `project` is what footprint and display paths are relative to; `cwd` (default: the
    /// project) is what a relative path in a shell command resolves against — the integrator
    /// runs in the intake's work dir, not the project.
    public init(harness: Harness, project: URL, cwd: URL? = nil, now: @escaping @Sendable () -> Date) {
        self.project = project.standardizedFileURL
        self.cwd = (cwd ?? project).standardizedFileURL
        self.now = now
        activity = SeatActivity(harness: harness, startedAt: now())
    }

    public mutating func feed(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            fold(line)
            pending.removeSubrange(pending.startIndex...newline)
        }
    }

    /// The process exited: fold a final line that never got its newline, and mark the seat
    /// finished. `exitCode` nil means it was stopped before it could exit on its own; `error`
    /// is the caller's own reason when the stream can't have one (the child never spawned).
    /// An error the stream already reported wins over both — it is the more specific.
    public mutating func finish(exitCode: Int32?, error: String? = nil) {
        if !pending.isEmpty { fold(pending); pending.removeAll() }
        activity.finished = true
        guard activity.error == nil else { return }
        if let error { activity.error = error; return }
        switch exitCode {
        case nil: activity.error = "stopped"
        case 0?: break
        case let code?: activity.error = "exited \(code)"
        }
    }

    // MARK: - Fold

    private mutating func fold(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // agy tags its events `event`, not `type` (agy 1.2.3 stream-json).
        if activity.harness == .gemini {
            guard let event = obj["event"] as? String ?? obj["type"] as? String else { return }
            activity.lastEventAt = now()
            foldGemini(event, obj)
            return
        }
        guard let type = obj["type"] as? String else { return }
        activity.lastEventAt = now()
        switch activity.harness {
        case .codex: foldCodex(type, obj)
        case .claude: foldClaude(type, obj)
        case .grok: foldGrok(type, obj)
        // Unreachable: gemini (agy) tags its events `event`, so it is folded above.
        case .gemini: break
        }
    }

    /// grok `--output-format streaming-messages-json` is claude's stream shape (`assistant`
    /// messages of `thinking`/`tool_use` blocks, a final `result`) with grok's own tool names.
    /// It has no `rate_limit_event`, so a grok seat never reports usage windows.
    private mutating func foldGrok(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }
            if let usage = message["usage"] as? [String: Any] {
                // Keyed per message like claude's, so a message whose usage repeats on every
                // block is counted once; a message with no id is its own entry.
                let id = message["id"] as? String ?? "grok-\(claudeUsage.count)"
                claudeUsage[id] = (claudeInput(usage), int(usage["output_tokens"]))
                activity.inputTokens = claudeUsage.values.reduce(0) { $0 + $1.input }
                activity.outputTokens = claudeUsage.values.reduce(0) { $0 + $1.output }
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "thinking": setHeadline(block["thinking"] as? String)
                case "tool_use": foldGrokTool(block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:])
                default: break
                }
            }
        case "result":
            if let cost = obj["total_cost_usd"] as? Double { activity.costUSD = cost }
            if let usage = obj["usage"] as? [String: Any] {
                // grok zeroes every bucket when its usage ledger is incomplete — "unknown",
                // not "nothing"; keep the per-message sums rather than overwrite them with 0.
                let input = claudeInput(usage), output = int(usage["output_tokens"])
                if input + output > 0 { activity.inputTokens = input; activity.outputTokens = output }
            }
            if obj["is_error"] as? Bool == true {
                let errors = (obj["errors"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["message"] as? String ?? $0 as? String }
                activity.error = errors.first ?? obj["result"] as? String ?? obj["subtype"] as? String ?? "error"
            }
            activity.finished = true
        case "error":
            activity.error = obj["message"] as? String ?? "error"
        default: break
        }
    }

    /// grok's internal tool ids (`--tools` vocabulary). Its file tools name their path
    /// `target_file`/`path` rather than claude's `file_path`, so every spelling is tried.
    private mutating func foldGrokTool(_ name: String, _ input: [String: Any]) {
        let path = ["target_file", "file_path", "path", "filePath", "file"].lazy.compactMap { input[$0] as? String }.first
        switch name {
        case "read_file":
            if let path { touch(path) }
            activity.action = ActivityAction(verb: "Reading", object: path.map(display))
        case "search_replace", "write", "write_file", "edit_file", "apply_patch", "delete_file":
            if let path { touch(path) }
            activity.action = ActivityAction(verb: "Editing", object: path.map(display))
        case "grep", "file_search":
            let pattern = input["pattern"] as? String ?? input["query"] as? String
            activity.action = ActivityAction(verb: "Searching", object: pattern.map(quoted))
        case "list_dir", "glob":
            let target = input["target_directory"] as? String ?? input["pattern"] as? String ?? path
            activity.action = ActivityAction(verb: "Listing", object: target.map(display))
        case "run_terminal_cmd":
            if let command = input["command"] as? String { foldCommand(command, unwrapShell: false) }
        case "web_search":
            activity.action = ActivityAction(verb: "Searching the web", object: input["query"] as? String)
        case "web_fetch":
            activity.action = ActivityAction(verb: "Fetching", object: input["url"] as? String)
        case "todo_write":
            let todos = input["todos"] as? [[String: Any]] ?? []
            let done = todos.filter { $0["status"] as? String == "completed" }.count
            let active = todos.first { $0["status"] as? String == "in_progress" }
                ?? todos.first { $0["status"] as? String != "completed" }
            activity.steps = ActivitySteps(done: done, total: todos.count,
                                           current: active.flatMap { $0["content"] as? String })
        case "StructuredOutput":
            // `--json-schema`'s answer tool, as with claude: the seat handing back its result.
            break
        default:
            activity.action = ActivityAction(verb: "Using", object: name.isEmpty ? nil : name)
        }
    }

    /// `agy --output-format stream-json`: `init`, then one `step_update` per step state change
    /// (`step_type` user_input / agent_response / tool / checkpoint), then `result`.
    private mutating func foldGemini(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "step_update":
            guard let step = obj["step_update"] as? [String: Any] else { return }
            if let usage = step["usage"] as? [String: Any] { foldGeminiUsage(usage) }
            switch step["step_type"] as? String {
            case "tool":
                let info = step["tool_info"] as? [String: Any] ?? [:]
                let name = step["tool_name"] as? String ?? info["name"] as? String ?? ""
                foldGeminiTool(name, geminiParameters(info["parameters"]))
            case "agent_response":
                // The model's own words while it works: its first sentence is the headline,
                // the nearest thing agy streams to claude's thinking or codex's reasoning.
                // Not when that text is the structured answer itself: a headline reading
                // `{"changeSet": …` says nothing.
                if let text = step["text_delta"] as? String {
                    geminiResponse += text
                    let lead = geminiResponse.trimmingCharacters(in: .whitespacesAndNewlines).first
                    if let lead, !"{[`".contains(lead) { setHeadline(geminiResponse) }
                }
            default: break
            }
        case "result":
            let result = obj["result"] as? [String: Any] ?? [:]
            if let usage = result["usage"] as? [String: Any] { foldGeminiUsage(usage) }
            if let status = result["status"] as? String, status != "SUCCESS" {
                activity.error = result["error"] as? String ?? status
            } else if result["structured_output"] == nil,
                      let denied = result["denied_actions"] as? [[String: Any]], !denied.isEmpty {
                // SUCCESS with no answer: agy auto-denied a tool and ended the turn (probed
                // 2026-10-07). The row says what was denied rather than looking finished-fine.
                activity.error = "denied: " + denied.compactMap { $0["action"] as? String }.joined(separator: ", ")
            }
            activity.finished = true
        default: break
        }
    }

    private mutating func foldGeminiUsage(_ usage: [String: Any]) {
        activity.inputTokens = int(usage["input_tokens"]) + int(usage["cache_read_tokens"])
        activity.outputTokens = int(usage["output_tokens"]) + int(usage["thinking_tokens"])
    }

    /// `tool_info.parameters` arrives as an object, or as that object's JSON text.
    private func geminiParameters(_ any: Any?) -> [String: Any] {
        if let dict = any as? [String: Any] { return dict }
        if let text = any as? String, let dict = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return dict
        }
        return [:]
    }

    /// agy's tool names (the Antigravity agent's tool set). Unknown ones read "Using <name>".
    private mutating func foldGeminiTool(_ name: String, _ input: [String: Any]) {
        let path = ["AbsolutePath", "absolute_path", "file_path", "path", "TargetFile", "target_file", "DirectoryPath",
                    "directory_path", "SearchPath", "search_path"].lazy.compactMap { input[$0] as? String }.first
        switch name {
        case "view_file", "read_file", "view_file_outline", "view_code_item":
            if let path { touch(path) }
            activity.action = ActivityAction(verb: "Reading", object: path.map(display))
        case "write_to_file", "replace_file_content", "multi_replace_file_content", "write_file", "edit_file", "replace":
            if let path { touch(path) }
            activity.action = ActivityAction(verb: "Editing", object: path.map(display))
        case "grep_search", "search_file_content", "codebase_search":
            let query = ["Query", "query", "pattern"].lazy.compactMap { input[$0] as? String }.first
            activity.action = ActivityAction(verb: "Searching", object: query.map(quoted))
        case "list_dir", "find_by_name", "list_directory", "glob":
            activity.action = ActivityAction(verb: "Listing", object: path.map(display))
        case "run_command", "run_shell_command":
            if let command = ["CommandLine", "command_line", "command"].lazy.compactMap({ input[$0] as? String }).first {
                foldCommand(command, unwrapShell: false)
            } else {
                activity.action = ActivityAction(verb: "Running", object: nil)
            }
        case "search_web", "google_web_search":
            activity.action = ActivityAction(verb: "Searching the web", object: input["query"] as? String)
        case "read_url_content", "web_fetch":
            activity.action = ActivityAction(verb: "Fetching", object: (input["Url"] ?? input["url"]) as? String)
        default:
            activity.action = ActivityAction(verb: "Using", object: name.isEmpty ? nil : name)
        }
    }

    private mutating func foldCodex(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "turn.completed":
            // Per turn; summed so a stream that ever carries two turns still reads cumulative.
            if let usage = obj["usage"] as? [String: Any] {
                codexTurns.input += int(usage["input_tokens"]); codexTurns.output += int(usage["output_tokens"])
                activity.inputTokens = codexTurns.input; activity.outputTokens = codexTurns.output
            }
            // `codex exec` runs exactly one turn, so its end is the seat's end.
            activity.finished = true
        case "turn.failed":
            activity.error = (obj["error"] as? [String: Any])?["message"] as? String ?? "turn failed"
            activity.finished = true
        case "error":
            activity.error = obj["message"] as? String ?? "error"
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return }
            foldCodexItem(item)
        default: break
        }
    }

    private mutating func foldCodexItem(_ item: [String: Any]) {
        switch item["type"] as? String {
        case "reasoning":
            setHeadline(item["text"] as? String)
        case "command_execution":
            if let command = item["command"] as? String { foldCommand(command) }
        case "file_change":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            paths.forEach { touch($0) }
            if let first = paths.first { activity.action = ActivityAction(verb: "Editing", object: display(first)) }
        case "mcp_tool_call":
            activity.action = ActivityAction(verb: "Using", object: item["tool"] as? String)
        case "web_search":
            activity.action = ActivityAction(verb: "Searching the web", object: item["query"] as? String)
        case "todo_list":
            let items = item["items"] as? [[String: Any]] ?? []
            let done = items.filter { $0["completed"] as? Bool == true }.count
            let current = items.first { $0["completed"] as? Bool != true }?["text"] as? String
            activity.steps = ActivitySteps(done: done, total: items.count, current: current)
        default: break
        }
    }

    private mutating func foldClaude(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "assistant":
            activity.rateLimitedAt = nil
            guard let message = obj["message"] as? [String: Any] else { return }
            if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] {
                claudeUsage[id] = (claudeInput(usage), int(usage["output_tokens"]))
                activity.inputTokens = claudeUsage.values.reduce(0) { $0 + $1.input }
                activity.outputTokens = claudeUsage.values.reduce(0) { $0 + $1.output }
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "thinking": setHeadline(block["thinking"] as? String)
                case "tool_use": foldClaudeTool(block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:])
                default: break
                }
            }
        case "rate_limit_event":
            // Emitted on every call, mostly `allowed`; only a rejection is a limit worth showing.
            let info = obj["rate_limit_info"] as? [String: Any] ?? [:]
            if ClaudeRateLimitParser.isRejected(rateLimitInfo: info) { activity.rateLimitedAt = now() }
            let windows = ClaudeRateLimitParser.windows(rateLimitInfo: info)
            if !windows.isEmpty { activity.rateLimitWindows = windows }
            if let status = info["status"] as? String { activity.rateLimitStatus = status }
            if let resets = ClaudeRateLimitParser.resetsAt(rateLimitInfo: info) { activity.rateLimitResetsAt = resets }
        case "result":
            if let cost = obj["total_cost_usd"] as? Double { activity.costUSD = cost }
            if let usage = obj["usage"] as? [String: Any] {
                activity.inputTokens = claudeInput(usage); activity.outputTokens = int(usage["output_tokens"])
            }
            if obj["is_error"] as? Bool == true {
                activity.error = obj["result"] as? String ?? obj["subtype"] as? String ?? "error"
            }
            activity.finished = true
        default: break
        }
    }

    private mutating func foldClaudeTool(_ name: String, _ input: [String: Any]) {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        switch name {
        case "Read":
            if let path { touch(path) }
            activity.action = ActivityAction(verb: "Reading", object: path.map(display))
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let path { touch(path) }
            activity.action = ActivityAction(verb: "Editing", object: path.map(display))
        case "Grep":
            activity.action = ActivityAction(verb: "Searching", object: (input["pattern"] as? String).map(quoted))
        case "Glob":
            activity.action = ActivityAction(verb: "Listing", object: input["pattern"] as? String)
        case "Bash":
            if let command = input["command"] as? String { foldCommand(command, unwrapShell: false) }
        case "WebSearch":
            activity.action = ActivityAction(verb: "Searching the web", object: input["query"] as? String)
        case "WebFetch":
            activity.action = ActivityAction(verb: "Fetching", object: input["url"] as? String)
        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            let done = todos.filter { $0["status"] as? String == "completed" }.count
            let active = todos.first { $0["status"] as? String == "in_progress" }
                ?? todos.first { $0["status"] as? String != "completed" }
            activity.steps = ActivitySteps(done: done, total: todos.count,
                                           current: active.flatMap { $0["activeForm"] as? String ?? $0["content"] as? String })
        case "StructuredOutput":
            // `--json-schema`'s answer tool: the run handing back its result, not an action —
            // the row keeps showing the last real thing the seat did.
            break
        default:
            // `mcp__<server>__<tool>`: the tool is the part a human recognises.
            let tool = name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
            activity.action = ActivityAction(verb: "Using", object: tool.isEmpty ? nil : tool)
        }
    }

    // MARK: - Shell commands

    /// codex reports every command as `/bin/zsh -lc "<script>"`; claude's Bash tool hands over
    /// the bare script. The script's first real command decides the verb — `cd` and variable
    /// assignments are setup, and a pipeline is named by its producer (`rg … | head`).
    private mutating func foldCommand(_ command: String, unwrapShell: Bool = true) {
        var words = ShellWords.split(command)
        if unwrapShell, words.count >= 3, let shell = words.first?.word, shell.hasSuffix("sh"),
           words[1].word.hasPrefix("-"), words[1].word.contains("c") {
            words = ShellWords.split(words[2].word)
        }
        let segments = ShellWords.commands(words)
        for segment in segments { readTargets(segment).forEach { touch($0) } }
        guard let primary = segments.first(where: { $0.first != "cd" }) ?? segments.first, let tool = primary.first else { return }
        activity.action = action(tool: (tool as NSString).lastPathComponent, args: Array(primary.dropFirst()))
    }

    private func action(tool: String, args: [String]) -> ActivityAction {
        switch tool {
        case "cat", "head", "tail", "less", "bat", "nl":
            return ActivityAction(verb: "Reading", object: readTargets([tool] + args).first.map(display))
        case "sed" where args.contains("-n"):
            return ActivityAction(verb: "Reading", object: readTargets([tool] + args).first.map(display))
        case "rg", "grep", "egrep", "ag":
            if args.contains("--files") { return ActivityAction(verb: "Listing", object: nil) }
            return ActivityAction(verb: "Searching", object: searchPattern(args).map(quoted))
        case "ls", "find", "fd", "tree":
            let target = args.first { !$0.hasPrefix("-") && $0 != "." }
            return ActivityAction(verb: "Listing", object: target)
        default:
            return ActivityAction(verb: "Running", object: ([tool] + args).joined(separator: " "))
        }
    }

    /// The files a reading command reads — what footprint counts for a shell command. Only the
    /// reading verbs: a `jq … file` or `swift build` touches files too, but naming them would
    /// mean guessing each tool's argument grammar.
    private func readTargets(_ command: [String]) -> [String] {
        guard let tool = command.first.map({ ($0 as NSString).lastPathComponent }) else { return [] }
        let args = Array(command.dropFirst())
        switch tool {
        case "cat", "less", "bat", "nl":
            return args.filter { !$0.hasPrefix("-") }
        case "head", "tail":
            var out: [String] = [], skip = false
            for a in args {
                if skip { skip = false; continue }
                if a == "-n" || a == "-c" { skip = true; continue }
                if !a.hasPrefix("-") { out.append(a) }
            }
            return out
        case "sed" where args.contains("-n"):
            // The first bare word is the script (`'1,240p'`) unless `-e` supplied it.
            var out: [String] = [], skip = false, sawScript = args.contains("-e")
            for a in args {
                if skip { skip = false; continue }
                if a == "-e" { skip = true; continue }
                if a.hasPrefix("-") { continue }
                if !sawScript { sawScript = true; continue }
                out.append(a)
            }
            return out
        default:
            return []
        }
    }

    private func searchPattern(_ args: [String]) -> String? {
        let valued: Set<String> = ["-g", "--glob", "-t", "--type", "-T", "--type-not", "-A", "-B", "-C", "-m",
                                   "--max-count", "--context", "-M", "--max-columns", "--include", "--exclude"]
        var skip = false
        for (i, a) in args.enumerated() {
            if skip { skip = false; continue }
            if a == "-e" || a == "--regexp" { return i + 1 < args.count ? args[i + 1] : nil }
            if valued.contains(a) { skip = true; continue }
            if a.hasPrefix("-") { continue }
            return a
        }
        return nil
    }

    // MARK: - Paths

    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : cwd.appendingPathComponent(expanded)).standardizedFileURL
    }

    /// Project-relative components, or nil for a path outside the project.
    private func relative(_ url: URL) -> [String]? {
        let root = project.pathComponents, parts = url.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        return Array(parts.dropFirst(root.count))
    }

    private func display(_ path: String) -> String {
        let url = resolve(path)
        return relative(url)?.joined(separator: "/") ?? url.path
    }

    private mutating func touch(_ path: String) {
        let url = resolve(path)
        guard touched.insert(url.path).inserted else { return }
        let bucket: String
        if let rel = relative(url) {
            bucket = rel.count == 1 ? "." : rel[0]
        } else {
            let parent = url.deletingLastPathComponent().lastPathComponent
            bucket = parent.isEmpty || parent == "/" ? "other" : parent
        }
        activity.footprint[bucket, default: 0] += 1
    }

    // MARK: - Text

    private mutating func setHeadline(_ text: String?) {
        guard let text, let h = Self.headline(text) else { return }
        activity.headline = h
    }

    /// First sentence of the first non-empty line, with markdown bold and heading marks gone.
    static func headline(_ text: String) -> String? {
        guard var line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            line = String(line[..<line.index(after: end.lowerBound)])
        }
        guard !line.isEmpty else { return nil }
        if line.count > headlineLimit {
            line = String(line.prefix(headlineLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return line
    }

    private func quoted(_ s: String) -> String { "\"\(s)\"" }

    private func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }

    private func claudeInput(_ usage: [String: Any]) -> Int {
        int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) + int(usage["cache_read_input_tokens"])
    }
}

/// Just enough POSIX shell word-splitting to name a command: single and double quotes, and
/// backslash escapes, with `&&`, `||`, `;`, `|` and newlines as command separators. Nothing is
/// expanded or executed — a word that would expand stays as written.
enum ShellWords {
    struct Token: Equatable { var word: String; var isOperator: Bool }

    static func split(_ s: String) -> [Token] {
        var out: [Token] = [], word = "", inWord = false
        var chars = Array(s)[...]
        func flush() { if inWord { out.append(Token(word: word, isOperator: false)); word = ""; inWord = false } }
        while let c = chars.popFirst() {
            switch c {
            case "'":
                inWord = true
                while let d = chars.popFirst(), d != "'" { word.append(d) }
            case "\"":
                inWord = true
                while let d = chars.popFirst(), d != "\"" {
                    if d == "\\", let e = chars.first, "$`\"\\\n".contains(e) { word.append(chars.removeFirst()) } else { word.append(d) }
                }
            case "\\":
                inWord = true
                if let e = chars.popFirst() { word.append(e) }
            case " ", "\t":
                flush()
            case "\n", ";":
                flush(); out.append(Token(word: ";", isOperator: true))
            case "&", "|":
                flush()
                if chars.first == c { chars.removeFirst(); out.append(Token(word: String([c, c]), isOperator: true)) }
                else { out.append(Token(word: String(c), isOperator: true)) }
            default:
                inWord = true; word.append(c)
            }
        }
        flush()
        return out
    }

    /// Each command's words, separators dropped and leading `VAR=value` assignments skipped.
    static func commands(_ tokens: [Token]) -> [[String]] {
        var out: [[String]] = [], current: [String] = []
        for t in tokens {
            if t.isOperator {
                if !current.isEmpty { out.append(current) }
                current = []
            } else if current.isEmpty, t.word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                continue
            } else {
                current.append(t.word)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
