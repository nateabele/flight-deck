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
    public init(harness: Harness, model: String, effort: String, cwd: URL, readableDirs: [URL],
                prompt: String, schemaFile: URL, schemaJSON: String, resumeSessionID: String?,
                access: HarnessAccess = .readOnly) {
        self.harness = harness; self.model = model; self.effort = effort; self.cwd = cwd
        self.readableDirs = readableDirs; self.prompt = prompt; self.schemaFile = schemaFile
        self.schemaJSON = schemaJSON; self.resumeSessionID = resumeSessionID; self.access = access
    }
}

public enum HarnessCommand {
    /// Read-only tool set for triage under `claude -p`: file reading plus `br`/`bv` READ verbs.
    /// FD is the only `br` writer (spec §5) — no `br create/update/dep` here.
    public static let claudeReadOnlyTools =
        "Read Grep Glob Bash(br list *) Bash(br show *) Bash(br graph *) Bash(br ready *) Bash(bv *)"

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

    /// Appended to EVERY headless claude run, read-only and write alike. `--allowedTools` and
    /// the denies above only ADD rules on top of the operator's own `~/.claude/settings.json`,
    /// so under `dontAsk` a read-only reviewer still inherits standing allows like
    /// `Bash(git add *)` — a "read-only" seat that can stage files. `--setting-sources local`
    /// drops the user and project settings files (keeping only the project's gitignored
    /// `settings.local.json`, an accepted residual). Probed live on claude 2.1.283,
    /// 2026-09-27: such a run still authenticates, since login lives in the keychain — but the
    /// probe's shell exported `ANTHROPIC_BASE_URL`, which hid the other half: the user
    /// settings' `env` block is dropped too. Every caller therefore re-applies it with
    /// `ClaudeUserEnv.merged(into:)` when building a claude child's environment.
    /// `--strict-mcp-config` with no `--mcp-config` drops every MCP server rather than guessing
    /// whether an `mcp__*` glob is valid `--disallowedTools` syntax.
    public static let claudeIsolation = ["--setting-sources", "local", "--strict-mcp-config"]

    /// The pure check behind `build`'s write-mode `precondition` — a request that fails this
    /// would sandbox the integrator somewhere other than its own work dir, or let it resume
    /// (the integrator always starts fresh), so `build` must never construct argv for it.
    /// Exposed separately so tests can exercise the failure without tripping the trap.
    public enum HarnessCommandError: Error, Equatable, Sendable {
        case cwdNotWorkDir
        case resumeNotSupportedForWrite
    }

    public static func validate(_ r: HarnessRequest) -> HarnessCommandError? {
        guard case .writeInWork(let dir) = r.access else { return nil }
        if r.cwd != dir { return .cwdNotWorkDir }
        if r.resumeSessionID != nil { return .resumeNotSupportedForWrite }
        return nil
    }

    public static func build(_ r: HarnessRequest) -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        if case .writeInWork = r.access {
            precondition(validate(r) == nil, "HarnessCommand.build: invalid write-mode request: \(String(describing: validate(r)))")
        }
        switch r.harness {
        case .codex:
            let effort = ["-m", r.model, "-c", "model_reasoning_effort=\(r.effort)"]
            let tail = ["--skip-git-repo-check", "--output-schema", r.schemaFile.path]
            if let s = r.resumeSessionID {
                // `exec resume` has no -s flag, and IGNORES the session's recorded model unless
                // -m is passed again (observed 2026-09-26: luna → terra). Pin both.
                return ("codex", ["exec", "resume", "--json"] + effort + ["-c", "sandbox_mode=\"read-only\""] + tail + [s, r.prompt], [])
            }
            let sandbox: String
            switch r.access {
            case .readOnly: sandbox = "read-only"
            case .writeInWork: sandbox = "workspace-write"
            }
            return ("codex", ["exec", "--json"] + effort + ["-s", sandbox] + tail + [r.prompt], [])
        case .claude:
            // `--permission-mode dontAsk`: a user `defaultMode: bypassPermissions` would
            // otherwise skip every check, allow list included. `dontAsk` denies anything not
            // pre-approved rather than prompting — there is nobody to answer a prompt under
            // `-p`. (`default` is not a choice in claude 2.1.283's `--help`: acceptEdits,
            // auto, bypassPermissions, manual, dontAsk, plan.)
            var args: [String]
            switch r.access {
            case .readOnly:
                args = ["-p", r.prompt, "--model", r.model, "--effort", r.effort, "--output-format", "json",
                        "--json-schema", r.schemaJSON, "--permission-mode", "dontAsk",
                        "--allowedTools", claudeReadOnlyTools, "--disallowedTools", claudeDeniedTools]
                for d in r.readableDirs { args += ["--add-dir", d.path] }
            case .writeInWork(let dir):
                // readableDirs is deliberately NOT added here: every `--add-dir` also grants
                // Edit/Write, not just read access, so adding the intake root (the integrator's
                // one readableDir) would let it write outside its own work dir — the integrator
                // only ever needs to read plan.md/changes.json, which already live under `dir`.
                args = ["-p", r.prompt, "--model", r.model, "--effort", r.effort, "--output-format", "json",
                        "--json-schema", r.schemaJSON, "--permission-mode", "acceptEdits",
                        "--allowedTools", claudeWriteTools, "--disallowedTools", claudeWriteDeniedTools,
                        "--add-dir", dir.path]
            }
            args += claudeIsolation
            if let s = r.resumeSessionID { args += ["--resume", s] }
            // Without these unset, a claude spawned from inside Claude Code silently skips
            // saving its transcript — and then `--resume` has nothing to resume.
            return ("claude", args, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
        }
    }
}

public enum HarnessOutput {
    public enum ParseError: Error, Equatable { case noSession, noResult, notJSON(String) }

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
            guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
                throw ParseError.notJSON(String(decoding: stdout.prefix(400), as: UTF8.self))
            }
            guard let session = obj["session_id"] as? String else { throw ParseError.noSession }
            if let structured = obj["structured_output"] {
                return (session, try JSONSerialization.data(withJSONObject: structured))
            }
            guard let text = obj["result"] as? String else { throw ParseError.noResult }
            let data = Data(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ParseError.notJSON(text) }
            return (session, data)
        }
    }
}
