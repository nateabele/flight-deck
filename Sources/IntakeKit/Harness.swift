import Foundation

public struct HarnessRequest: Sendable {
    public var harness: Harness, model: String, effort: String
    public var cwd: URL, readableDirs: [URL], prompt: String
    public var schemaFile: URL, schemaJSON: String, resumeSessionID: String?
    public init(harness: Harness, model: String, effort: String, cwd: URL, readableDirs: [URL],
                prompt: String, schemaFile: URL, schemaJSON: String, resumeSessionID: String?) {
        self.harness = harness; self.model = model; self.effort = effort; self.cwd = cwd
        self.readableDirs = readableDirs; self.prompt = prompt; self.schemaFile = schemaFile
        self.schemaJSON = schemaJSON; self.resumeSessionID = resumeSessionID
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

    public static func build(_ r: HarnessRequest) -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        switch r.harness {
        case .codex:
            let effort = ["-m", r.model, "-c", "model_reasoning_effort=\(r.effort)"]
            let tail = ["--skip-git-repo-check", "--output-schema", r.schemaFile.path]
            if let s = r.resumeSessionID {
                // `exec resume` has no -s flag, and IGNORES the session's recorded model unless
                // -m is passed again (observed 2026-09-26: luna → terra). Pin both.
                return ("codex", ["exec", "resume", "--json"] + effort + ["-c", "sandbox_mode=\"read-only\""] + tail + [s, r.prompt], [])
            }
            return ("codex", ["exec", "--json"] + effort + ["-s", "read-only"] + tail + [r.prompt], [])
        case .claude:
            // `--permission-mode dontAsk`: a user `defaultMode: bypassPermissions` would
            // otherwise skip every check, allow list included. `dontAsk` denies anything not
            // pre-approved rather than prompting — there is nobody to answer a prompt under
            // `-p`. (`default` is not a choice in claude 2.1.283's `--help`: acceptEdits,
            // auto, bypassPermissions, manual, dontAsk, plan.)
            var args = ["-p", r.prompt, "--model", r.model, "--effort", r.effort, "--output-format", "json",
                        "--json-schema", r.schemaJSON, "--permission-mode", "dontAsk",
                        "--allowedTools", claudeReadOnlyTools, "--disallowedTools", claudeDeniedTools]
            for d in r.readableDirs { args += ["--add-dir", d.path] }
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
