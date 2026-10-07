import Foundation

/// Whether a harness runs read-only (triage, review, drafting — every seat but the integrator)
/// or may write inside its own work dir. Defaults to `.readOnly` on `HarnessRequest` so every
/// existing caller keeps producing byte-identical argv.
public enum HarnessAccess: Sendable, Equatable {
    case readOnly
    case writeInWork(URL)
}

public struct HarnessRequest: Sendable {
    public var harness: Harness, model: String, effort: String
    public var cwd: URL, readableDirs: [URL], prompt: String
    public var schemaFile: URL, schemaJSON: String, resumeSessionID: String?
    public var access: HarnessAccess
    /// The account this run bills (grok/gemini spec §3.0). nil is the built-in account — the
    /// CLI's own default home — so argv and environment are exactly what they were before
    /// accounts reached planning. A non-nil account is bound by the profile's
    /// `environment(base:account:)` (via `HarnessCommand.environment`) and, for codex, picks
    /// which `config.toml` `service_tier` is carried over from (`build`).
    public var account: AgentAccountRef?
    public init(harness: Harness, model: String, effort: String, cwd: URL, readableDirs: [URL],
                prompt: String, schemaFile: URL, schemaJSON: String, resumeSessionID: String?,
                access: HarnessAccess = .readOnly, account: AgentAccountRef? = nil) {
        self.harness = harness; self.model = model; self.effort = effort; self.cwd = cwd
        self.readableDirs = readableDirs; self.prompt = prompt; self.schemaFile = schemaFile
        self.schemaJSON = schemaJSON; self.resumeSessionID = resumeSessionID; self.access = access
        self.account = account
    }
}

public enum HarnessCommand {
    /// Read-only tool set for triage under `claude -p`: file reading plus `br` READ verbs. FD is
    /// the only `br` writer (spec §5) — no `br create/update/dep` here. `bv` is deliberately
    /// NOT on this list, for any claude seat: even `Bash(bv --db <path> *)`, scoped to one
    /// round's shadow, is still a prefix match against the WHOLE command line, so it would also
    /// match `bv`'s write/mutating flags on that same invocation (`--export*`, `--update --yes`,
    /// `--rollback`, `--save-baseline`, …). FD runs `bv` itself instead and hands the agent the
    /// resulting files — see `ShadowAnalytics` in RoundPrompts.swift.
    public static let claudeReadOnlyTools =
        "Read Grep Glob Bash(br list *) Bash(br show *) Bash(br graph *) Bash(br ready *)"

    /// Every `br` write verb, denied by name. `--allowedTools` only ADDS allow rules on top of
    /// the user's and project's settings, so a project `.claude/settings.json` allowing
    /// `Bash(br:*)` would still let triage write; deny rules beat allow rules wherever they
    /// come from, so this is what actually holds FD to being the only writer.
    public static let claudeDeniedTools = ["create", "update", "close", "reopen", "delete", "dep", "label",
                                           "comments", "sync", "defer", "undefer", "q", "init"]
        .map { "Bash(br \($0) *)" }.joined(separator: " ")

    /// The integrator's tool set: it merges triage output into files inside its own work dir, so
    /// it needs to write there — unlike every read-only seat, which only ever reads/greps/`br`s.
    public static let claudeWriteTools = "Read Edit Write"

    /// Non-edit tools denied in write mode, on top of `--strict-mcp-config` (below): granting
    /// exactly Read/Edit/Write via `--allowedTools` above is not a sandbox by itself, because
    /// `--allowedTools` only ADDS to whatever the operator's own settings.json already allows —
    /// and this machine's has standing allows like `Bash(git add *)` and `Bash(rg:*)` that
    /// `acceptEdits` would still run unprompted. A bare `Bash` deny beats every one of those
    /// allows regardless of where they came from, which is what actually confines the integrator
    /// to Read/Edit/Write; WebFetch/WebSearch/Task/NotebookEdit are denied the same way as
    /// defense in depth for the same reason, since none of them are edits either.
    public static let claudeWriteDeniedTools = "Bash WebFetch WebSearch Task NotebookEdit"

    /// The built-in tools a read-only seat is given at all. `--restricted` (below) removes
    /// Bash unless `--tools` names it, and every `br` read verb in `claudeReadOnlyTools` is a
    /// Bash rule — so without Bash here the seat could not read the graph. Naming Bash only
    /// makes it AVAILABLE: under `dontAsk`, anything the allow list above doesn't match is
    /// still denied. Probed live on claude 2.1.283, 2026-09-27: the init event lists exactly
    /// these four tools.
    public static let claudeReadOnlyBuiltins = "Read Grep Glob Bash"

    /// Appended to EVERY headless claude run, read-only and write alike. `--allowedTools` and
    /// the denies above only ADD rules on top of whatever settings files load, so under
    /// `dontAsk` a read-only reviewer would inherit standing allows like `Bash(git add *)` — a
    /// "read-only" seat that can stage files. `--restricted` ignores the user, project AND
    /// local settings files (the earlier `--setting-sources local` still loaded the project's
    /// `settings.local.json`), confines the file tools to the working directories plus
    /// `--add-dir`, and refuses `bypassPermissions`. Probed live on claude 2.1.283,
    /// 2026-09-27: a restricted run still authenticates, since login lives in the keychain —
    /// but the settings' `env` block (this machine's `ANTHROPIC_BASE_URL` proxy) is dropped
    /// with the file, so every caller builds the child's environment with
    /// `environment(for:base:home:)`, which re-applies it.
    /// `--strict-mcp-config` with no `--mcp-config` drops every MCP server rather than guessing
    /// whether an `mcp__*` glob is valid `--disallowedTools` syntax.
    public static let claudeIsolation = ["--restricted", "--strict-mcp-config"]

    /// Every headless claude run streams its events as JSONL, so a seat shows what it is doing
    /// while it works — `--output-format json` is silent until the very end. `-p` refuses
    /// stream-json without `--verbose`. Probed live on claude 2.1.283, 2026-09-27, with
    /// `--json-schema` and the isolation flags above, fresh and `--resume`: the stream ends in
    /// the same `result` object `json` printed alone, `structured_output` included (see
    /// `HarnessOutput.parse`).
    public static let claudeStreaming = ["--output-format", "stream-json", "--verbose"]

    /// Prepended to EVERY codex run, fresh, resumed and write alike. `-s` only sandboxes the
    /// shell commands the model runs; `~/.codex/config.toml` also starts MCP servers (quillmap,
    /// whose file mutators write anywhere) and `~/.codex/hooks.json` hooks, and both run
    /// OUTSIDE that sandbox — a read-only drafter that could still edit the user's repo.
    /// `--ignore-user-config` skips config.toml (auth still comes from `CODEX_HOME`),
    /// `--ignore-rules` skips execpolicy `.rules` allows, and `--disable hooks` turns the
    /// hooks feature off, since hooks.json is read from `CODEX_HOME` whether or not the config
    /// that enabled it loads. Probed live on codex-cli 0.157.1, 2026-09-27: such a run still
    /// authenticates and answers; this machine's config sets no `model_provider`/`base_url`
    /// that would need carrying over with `-c`. Every seat passes `-m` and effort explicitly,
    /// so losing the config's model defaults changes nothing a round depends on. The one
    /// setting that IS carried over is `service_tier` (`CodexUserConfig`), which `build`
    /// appends right after these.
    ///
    /// `model_reasoning_summary=detailed` is not isolation but has to ride with it: without the
    /// user config codex emits NO `reasoning` items at all, so every seat's live headline
    /// (`ActivityParser`) would stay blank. Probed on 0.157.1, 2026-09-27, at medium effort: the
    /// same prompt produced zero reasoning items without it and a `**Planning file inspection
    /// using built-ins**` summary with it.
    public static let codexIsolation = ["--ignore-user-config", "--ignore-rules", "--disable", "hooks",
                                        "-c", "model_reasoning_summary=detailed"]

    /// Write mode's workspace-write sandbox, narrowed to the work dir alone. By default codex
    /// also makes `$TMPDIR` and `/tmp` writable — shared scratch another process (or a later
    /// round) reads — and would add any configured `writable_roots`. Key names verified
    /// against the codex-cli 0.157.1 binary's config schema.
    public static let codexWriteSandbox = ["-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
                                           "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
                                           "-c", "sandbox_workspace_write.writable_roots=[]"]

    // MARK: grok (grok 1.0.30, 2026-10-07 — see GrokProfile for where each fact came from)

    /// grok has no single read-only switch, and `--permission-mode plan` is "accepted for
    /// compatibility" only — headless it enforces nothing. A read-only seat is therefore built
    /// from four independent layers, any one of which would hold alone against the common case:
    /// - `--tools` makes these the ONLY built-in tools that exist (no shell, no edit tool);
    /// - `--deny` rules beat every allow from every source, including the operator's
    ///   `~/.claude/settings.json` permissions, which grok also reads;
    /// - `--permission-mode dontAsk` auto-denies anything not pre-approved instead of
    ///   prompting nobody — and overrides a `bypassPermissions` default from those settings;
    /// - `--disallowed-tools Agent` / `--no-subagents` stop a subagent being spawned with a
    ///   tool set of its own.
    /// These three tools are on grok's own "never prompts" read-only list, so `dontAsk` lets
    /// them run without an allow rule.
    public static let grokReadOnlyTools = "read_file,grep,list_dir"

    /// Deny rules for every tool class that writes, executes or leaves the machine. Tool-class
    /// names are grok's rule vocabulary (`Edit` and `Write` are one class, both named so a
    /// rename of either can't reopen it); `MCPTool` with no pattern matches every MCP tool,
    /// so an MCP server that slipped past the isolation environment still can't be called.
    public static let grokDeniedRules = ["Edit", "Write", "Bash", "WebFetch", "WebSearch", "MCPTool"]

    /// The flags every grok seat gets. `streaming-messages-json` is the Anthropic stream shape:
    /// tool use streams as it happens (the seat's live row), and the final `result` line carries
    /// the answer, `structured_output`, `session_id` and usage. `--no-plan` keeps the
    /// interactive plan-mode tools (which write a plan file) out of a headless run.
    public static let grokCommon = ["--output-format", "streaming-messages-json", "--disable-web-search",
                                    "--no-subagents", "--no-plan", "--disallowed-tools", "Agent"]

    /// The integrator's built-in tools: read, plus the two edit tools (`search_replace` edits,
    /// `write` creates). Still no shell.
    public static let grokWriteTools = "read_file,grep,list_dir,search_replace,write"

    /// Denied in write mode — `Edit`/`Write` are absent because the integrator needs them; they
    /// are instead allowed ONLY under its work dir (`Edit(<dir>/**)`), and `dontAsk` denies an
    /// edit anywhere else rather than asking.
    public static let grokWriteDeniedRules = ["Bash", "WebFetch", "WebSearch", "MCPTool"]

    /// A new conversation's id. grok's `--session-id` must be a valid UUID that names no
    /// existing session; minting it here (rather than letting grok pick one) means a seat's id
    /// is known before the child even starts. The stream also reports it, and that reported id
    /// is what `HarnessOutput.parse` returns — the minted one only ever goes TO grok.
    static func mintGrokSessionID() -> String { UUID().uuidString.lowercased() }

    /// The pure check behind `build`'s write-mode `precondition` — a request that fails this
    /// would sandbox the integrator somewhere other than its own work dir, or let it resume
    /// (the integrator always starts fresh), so `build` must never construct argv for it.
    /// Exposed separately so tests can exercise the failure without tripping the trap.
    public enum HarnessCommandError: Error, Equatable, Sendable {
        case cwdNotWorkDir
        case resumeNotSupportedForWrite
        /// `build` has no arm for this harness yet (grok/gemini until Tracks G/M land). Thrown,
        /// never approximated: a guessed argv for a CLI nobody has probed could run a "read-only"
        /// seat with write tools, which is worse than a round that pauses saying why.
        case harnessNotImplemented(Harness)
    }

    public static func validate(_ r: HarnessRequest) -> HarnessCommandError? {
        guard case .writeInWork(let dir) = r.access else { return nil }
        if r.cwd != dir { return .cwdNotWorkDir }
        if r.resumeSessionID != nil { return .resumeNotSupportedForWrite }
        return nil
    }

    /// `home` is where `CodexUserConfig` reads the built-in account's `service_tier` from —
    /// injectable so a test never reads the operator's own config. A bound `r.account` reads
    /// its own home's instead (`CodexProfile.serviceTierArguments`).
    public static func build(_ r: HarnessRequest, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        throws(HarnessCommandError) -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        if case .writeInWork = r.access {
            precondition(validate(r) == nil, "HarnessCommand.build: invalid write-mode request: \(String(describing: validate(r)))")
        }
        switch r.harness {
        case .codex:
            let effort = ["-m", r.model, "-c", "model_reasoning_effort=\(r.effort)"] + codexIsolation
                + CodexProfile(userHome: home).serviceTierArguments(account: r.account)
            let tail = ["--skip-git-repo-check", "--output-schema", r.schemaFile.path]
            if let s = r.resumeSessionID {
                // `exec resume` has no -s flag, and IGNORES the session's recorded model unless
                // -m is passed again (observed 2026-09-26: luna → terra). Pin both.
                return ("codex", ["exec", "resume", "--json"] + effort + ["-c", "sandbox_mode=\"read-only\""] + tail + [s, r.prompt], [])
            }
            let sandbox: [String]
            switch r.access {
            case .readOnly: sandbox = ["-s", "read-only"]
            case .writeInWork: sandbox = ["-s", "workspace-write"] + codexWriteSandbox
            }
            return ("codex", ["exec", "--json"] + effort + sandbox + tail + [r.prompt], [])
        case .claude:
            // `--permission-mode dontAsk`: a user `defaultMode: bypassPermissions` would
            // otherwise skip every check, allow list included. `dontAsk` denies anything not
            // pre-approved rather than prompting — there is nobody to answer a prompt under
            // `-p`. (`default` is not a choice in claude 2.1.283's `--help`: acceptEdits,
            // auto, bypassPermissions, manual, dontAsk, plan.)
            var args: [String]
            switch r.access {
            case .readOnly:
                args = ["-p", r.prompt, "--model", r.model, "--effort", r.effort] + claudeStreaming + [
                        "--json-schema", r.schemaJSON, "--permission-mode", "dontAsk",
                        "--tools", claudeReadOnlyBuiltins, "--allowedTools", claudeReadOnlyTools, "--disallowedTools", claudeDeniedTools]
                for d in r.readableDirs { args += ["--add-dir", d.path] }
            case .writeInWork(let dir):
                // readableDirs is deliberately NOT added here: every `--add-dir` also grants
                // Edit/Write, not just read access, so adding the intake root (the integrator's
                // one readableDir) would let it write outside its own work dir — the integrator
                // only ever needs to read plan.md/changes.json, which already live under `dir`.
                args = ["-p", r.prompt, "--model", r.model, "--effort", r.effort] + claudeStreaming + [
                        "--json-schema", r.schemaJSON, "--permission-mode", "acceptEdits",
                        // `--tools` makes Read/Edit/Write the ONLY tools that exist, not just
                        // the only pre-approved ones (probed: the init event lists exactly
                        // these three); the denies below stay as defense in depth.
                        "--tools", claudeWriteTools, "--allowedTools", claudeWriteTools, "--disallowedTools", claudeWriteDeniedTools,
                        "--add-dir", dir.path]
            }
            args += claudeIsolation
            if let s = r.resumeSessionID { args += ["--resume", s] }
            // Without these unset, a claude spawned from inside Claude Code silently skips
            // saving its transcript — and then `--resume` has nothing to resume.
            return ("claude", args, ClaudeProfile.childSessionVariables)
        case .grok:
            var args = ["-p", r.prompt, "--json-schema", r.schemaJSON, "-m", r.model]
            // An empty effort means "the model's own default" — `--reasoning-effort ""` would be
            // rejected as an unknown level, failing the seat over a knob nobody set.
            if !r.effort.isEmpty { args += ["--reasoning-effort", r.effort] }
            args += ["--cwd", r.cwd.path] + grokCommon + ["--permission-mode", "dontAsk"]
            switch r.access {
            case .readOnly:
                // `readableDirs` needs no flag: `read_file`/`grep` are not path-confined in
                // grok, so the intake dir is already readable. Narrowing reads with
                // `Read(...)` rules would only add a way to lock the seat out of its inputs.
                args += ["--tools", grokReadOnlyTools]
                for rule in grokDeniedRules { args += ["--deny", rule] }
            case .writeInWork(let dir):
                args += ["--tools", grokWriteTools, "--allow", "Edit(\(dir.path)/**)"]
                for rule in grokWriteDeniedRules { args += ["--deny", rule] }
            }
            // Never a title, never bare `--resume` (= the most recent session in this cwd, which
            // with parallel seats is another seat's): always a UUID, which grok treats as an id.
            if let s = r.resumeSessionID { args += ["--resume", s] } else { args += ["--session-id", mintGrokSessionID()] }
            return ("grok", args, [])
        case .gemini:
            throw .harnessNotImplemented(r.harness)
        }
    }

    /// The complete environment for a child `build` produced, from the caller's resolved
    /// `base` (PATH already repaired). The ONE place triage (`SystemHeadlessRunner`), every
    /// round (`RoundExecutor`) and the rule compiler get it from, so they can't drift. The
    /// CLI's own profile builds it — for claude, the account's settings `env` back underneath
    /// `base` (`--restricted` drops the file that carries it), the account's home bound, and the
    /// child-session scrub — and then `build`'s unsets run, so nothing can re-introduce a
    /// variable `build` removed. `account` nil is the built-in account. `home` is injectable so
    /// a test never reads the operator's own settings.
    public static func environment(
        for command: (executable: String, arguments: [String], unsetEnvironment: [String]),
        base: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
        account: AgentAccountRef? = nil
    ) -> [String: String] {
        var environment: [String: String]
        switch command.executable {
        case ClaudeProfile().binaryName: environment = ClaudeProfile(userHome: home).environment(base: base, account: account)
        case CodexProfile().binaryName: environment = CodexProfile(userHome: home).environment(base: base, account: account)
        // The isolation that keeps a grok seat off the operator's Claude/Cursor hooks and MCP
        // servers is environment, not argv (see `GrokProfile.isolationEnvironment`) — so every
        // grok child, triage and round alike, must come through here.
        case GrokProfile().binaryName: environment = GrokProfile().environment(base: base, account: account)
        default: environment = base
        }
        for key in command.unsetEnvironment { environment.removeValue(forKey: key) }
        return environment
    }
}

public enum HarnessOutput {
    public enum ParseError: Error, Equatable {
        case noSession, noResult, notJSON(String), isError(String)
        /// No parser for this harness yet (grok/gemini until Tracks G/M land). Unreachable in
        /// practice — `build` refuses first — but a parse that guessed would hand an unvalidated
        /// answer to the round.
        case harnessNotImplemented(Harness)
    }

    public static func parse(_ harness: Harness, stdout: Data) throws -> (sessionID: String, structured: Data) {
        switch harness {
        case .codex:
            var session: String?, text: String?
            for line in stdout.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if obj["type"] as? String == "thread.started" { session = obj["thread_id"] as? String }
                if obj["type"] as? String == "item.completed",
                   let item = obj["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    text = item["text"] as? String
                }
            }
            guard let session else { throw ParseError.noSession }
            guard let text else { throw ParseError.noResult }
            let data = Data(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ParseError.notJSON(text) }
            return (session, data)
        case .claude:
            // `--output-format json`'s single object — kept for fixtures recorded before claude
            // seats streamed.
            if let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
                guard let session = obj["session_id"] as? String else { throw ParseError.noSession }
                return (session, try claudeStructured(obj))
            }
            // stream-json: the session id is on the leading `system/init` line (and every
            // event after it); the answer is the final `result` event. A stream that never got
            // that far — killed, crashed — has no answer, whatever it said on the way.
            var session: String?, result: [String: Any]?
            for line in stdout.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let s = obj["session_id"] as? String { session = s }
                if obj["type"] as? String == "result" { result = obj }
            }
            guard let session else { throw ParseError.noSession }
            guard let result else { throw ParseError.noResult }
            return (session, try claudeStructured(result))
        case .grok:
            return try grokParse(stdout)
        case .gemini:
            throw ParseError.harnessNotImplemented(harness)
        }
    }

    /// grok `--output-format streaming-messages-json`: NDJSON whose every line carries
    /// `session_id`, ending in one `result` line with the answer (`structured_output` under
    /// `--json-schema`). Also accepts the single-object `--output-format json` shape
    /// (`sessionId`, `text`), which `--json-schema` alone implies — so a run whose explicit
    /// format grok ever stops honouring still parses instead of pausing the round.
    private static func grokParse(_ stdout: Data) throws -> (sessionID: String, structured: Data) {
        var session: String?, result: [String: Any]?
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            // A run that failed before starting a session reports `"session_id":""` (probed:
            // signed out, grok 1.0.30) — empty is "none", never an id to resume.
            if let s = obj["session_id"] as? String ?? obj["sessionId"] as? String, !s.isEmpty { session = s }
            if obj["type"] as? String == "result" || (obj["type"] == nil && obj["text"] != nil) { result = obj }
        }
        if var failed = result, failed["is_error"] as? Bool == true {
            // Checked before the session: a failed run's error is the more useful report, and it
            // may have no session at all. Its reason is in `errors[]` (strings, probed), with
            // `result` absent — surface that rather than the bare subtype.
            if failed["result"] == nil, let errors = failed["errors"] as? [Any], !errors.isEmpty {
                failed["result"] = errors.map { ($0 as? [String: Any])?["message"] as? String ?? "\($0)" }.joined(separator: "; ")
            }
            throw ParseError.isError(failed["result"] as? String ?? failed["subtype"] as? String ?? "is_error")
        }
        guard let session else { throw ParseError.noSession }
        guard var result else { throw ParseError.noResult }
        if result["result"] == nil, let text = result["text"] as? String { result["result"] = text }
        if result["structured_output"] == nil, let structured = result["structuredOutput"] { result["structured_output"] = structured }
        return (session, try claudeStructured(result))
    }

    /// The structured answer in a claude `result` object. `is_error` means `result` holds the
    /// error text, not an answer — parsing it as one would pass a JSON-shaped error message
    /// off as the seat's output.
    private static func claudeStructured(_ obj: [String: Any]) throws -> Data {
        if obj["is_error"] as? Bool == true {
            throw ParseError.isError(obj["result"] as? String ?? obj["subtype"] as? String ?? "is_error")
        }
        if let structured = obj["structured_output"] {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        guard let text = obj["result"] as? String else { throw ParseError.noResult }
        let data = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ParseError.notJSON(text) }
        return data
    }
}
