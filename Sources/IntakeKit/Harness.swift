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
    /// CLI's own default home — which is every caller today, so argv and environment are
    /// unchanged. Binding a non-nil account is the profile's `environment(base:account:)` job,
    /// wired in by Track P; until then this is carried, never read.
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

    /// `home` is where `CodexUserConfig` reads `service_tier` from — injectable so a test never
    /// reads the operator's own config.
    public static func build(_ r: HarnessRequest, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        throws(HarnessCommandError) -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        if case .writeInWork = r.access {
            precondition(validate(r) == nil, "HarnessCommand.build: invalid write-mode request: \(String(describing: validate(r)))")
        }
        switch r.harness {
        case .codex:
            let effort = ["-m", r.model, "-c", "model_reasoning_effort=\(r.effort)"] + codexIsolation
                + CodexUserConfig.arguments(home: home)
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
            return ("claude", args, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
        case .gemini:
            return ("agy", geminiArguments(r), [])
        case .grok:
            throw .harnessNotImplemented(r.harness)
        }
    }

    /// `agy`'s own wait on a print-mode run defaults to 5 minutes (agy 1.2.3 `--help`), after
    /// which it gives up on a seat that is still working — shorter than a real drafter or
    /// integrator turn. Two hours is the same "never cut a seat short" the claude and codex
    /// seats get by having no timeout at all, while still bounding a wedged child.
    public static let geminiPrintTimeout = ["--print-timeout", "2h"]

    /// Every headless `agy` run. stream-json so the seat shows live activity (the final
    /// `result` event carries the same object `--output-format json` prints alone);
    /// `--json-schema` takes a file path or inline JSON, and the file keeps a large schema out
    /// of argv. `--disable-slash-commands` stops a prompt line that happens to start with `/`
    /// expanding into a skill or command — the seat's prompt is data, not a command.
    static func geminiArguments(_ r: HarnessRequest) -> [String] {
        var args = ["-p", r.prompt, "--output-format", "stream-json", "--json-schema", r.schemaFile.path,
                    "--model", r.model]
        if !r.effort.isEmpty { args += ["--effort", r.effort] }
        args += ["--disable-slash-commands"] + geminiPrintTimeout
        switch r.access {
        case .readOnly:
            // `--mode plan`: agy's read-only execution mode. Readable dirs join the workspace
            // with `--add-dir`, the way claude seats get them.
            args += ["--mode", "plan"]
            for d in r.readableDirs { args += ["--add-dir", d.path] }
        case .writeInWork:
            // `accept-edits` lets file edits through without a prompt nobody could answer; the
            // workspace is the cwd, which `validate` pins to the work dir. readableDirs are NOT
            // added: `--add-dir` widens the workspace, i.e. where edits may land.
            args += ["--mode", "accept-edits"]
        }
        // Resume by the id agy itself reported (`conversation_id`). Never `--continue`: it
        // resumes the MOST RECENT conversation, which with parallel seats is another seat's.
        if let s = r.resumeSessionID { args += ["--conversation", s] }
        return args
    }

    /// The complete environment for a child `build` produced, from the caller's resolved
    /// `base` (PATH already repaired). The ONE place both triage (`SystemHeadlessRunner`) and
    /// every round (`RoundExecutor`) get it from, so the two can't drift: a claude child gets
    /// the user settings' `env` back underneath `base` (see `ClaudeUserEnv` — `--restricted`
    /// drops the file that carries it), then the unsets, so the settings file can never
    /// re-introduce a variable `build` removed. `home` is injectable so a test never reads the
    /// operator's own settings.
    public static func environment(
        for command: (executable: String, arguments: [String], unsetEnvironment: [String]),
        base: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = command.executable == "claude" ? ClaudeUserEnv.merged(into: base, home: home) : base
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
        case .gemini:
            return try geminiParse(stdout)
        case .grok:
            throw ParseError.harnessNotImplemented(harness)
        }
    }

    /// `agy --output-format stream-json`: `{"event":"init","conversation_id":…}` first, then
    /// `step_update`s, then `{"event":"result","result":{…}}` — the same object
    /// `--output-format json` prints alone, which is accepted too. The session is the result's
    /// `conversation_id` (or init's, when the result has none). A result whose `status` is not
    /// `SUCCESS` holds an error, not an answer — and a signed-out run reports one with an EMPTY
    /// conversation id, so the status is checked before the id.
    private static func geminiParse(_ stdout: Data) throws -> (sessionID: String, structured: Data) {
        var session: String?, result: [String: Any]?
        if let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any], obj["event"] == nil {
            result = obj
        } else {
            for line in stdout.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let s = obj["conversation_id"] as? String, !s.isEmpty { session = s }
                if obj["event"] as? String == "result" { result = obj["result"] as? [String: Any] }
            }
        }
        guard let result else { throw session == nil ? ParseError.noSession : ParseError.noResult }
        let status = result["status"] as? String ?? ""
        guard status == "SUCCESS" else {
            throw ParseError.isError(result["error"] as? String ?? (status.isEmpty ? "no status" : status))
        }
        if let s = result["conversation_id"] as? String, !s.isEmpty { session = s }
        guard let session else { throw ParseError.noSession }
        if let structured = result["structured_output"], !(structured is NSNull) {
            return (session, try JSONSerialization.data(withJSONObject: structured, options: .fragmentsAllowed))
        }
        guard let text = result["response"] as? String else { throw ParseError.noResult }
        let data = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ParseError.notJSON(text) }
        return (session, data)
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
