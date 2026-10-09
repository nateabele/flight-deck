import Foundation

/// OpenCode (`opencode`), as a headless planning harness: `opencode run --format json`.
///
/// Every fact below was probed on opencode 1.18.34 (the version `/global/health` reported) on
/// 2026-10-09, against `scripts/opencodeprobe/fake_llm.py` as the model — a scripted
/// OpenAI-compatible endpoint, so every tool call was one the probe asked for and no tokens were
/// spent. OpenCode auto-updates, so a comment here is pinned to that version, never to "opencode".
public struct OpenCodeProfile: AgentProfile {
    public init() {}
    public var id: AgentID { .opencode }
    public var binaryName: String { "opencode" }

    /// The variable that relocates OpenCode's DATA: its session database and its provider
    /// credentials (`auth.json`), both in `$XDG_DATA_HOME/opencode`. Probed: with it pointed at a
    /// scratch root, `opencode auth list` reported `<root>/opencode/auth.json`. OpenCode has no
    /// variable that moves its data directory alone (`OPENCODE_DB` moves only the database), so
    /// an account's home is an XDG data root and two accounts are two roots — `~/.local/share`
    /// and a sibling such as `~/.local/share-work`. Config (`~/.config/opencode`) is NOT moved:
    /// providers, models and agents stay the person's own, only the logins differ.
    public static let homeEnvironmentKey = "XDG_DATA_HOME"

    public static let signInHint = "OpenCode: run `opencode auth login`, or configure a provider"

    /// `opencode models` lists every model of every provider OpenCode can reach — signed-in
    /// providers, locally configured ones (Ollama) and OpenCode's own free models — without
    /// calling a model. It exits 0 either way, so readiness is "it listed at least one model":
    /// a model OpenCode lists is one a run can use.
    public var signInCheck: SignInCheck {
        SignInCheck(arguments: ["models"], signedOutHint: Self.signInHint) { output in
            output.exitCode == 0 && !OpenCodeProfile().parseModelList(output.stdout).isEmpty
        }
    }

    /// No aliases and no hard-coded default: OpenCode serves whatever providers the person set
    /// up, so the only honest list is `opencode models`' own. An empty default model means
    /// "OpenCode's configured default" — `build` then passes no `-m` at all.
    ///
    /// No effort knob. OpenCode's `--variant` is provider-specific ("high, max, minimal"), and
    /// a value one provider accepts another rejects, so offering a fixed list would let a seat
    /// pick a level its model refuses.
    public var modelCatalog: ProfileModelCatalog {
        ProfileModelCatalog(aliases: [], listArguments: ["models"], defaultPlanningModel: "",
                            defaultPlanningEffort: "", effortValues: [])
    }

    /// One `provider/model` per line (e.g. `opencode/big-pickle`, `ollama/qwen3-coder:30b`).
    /// A line without a slash is not a model id (a banner, a warning) and is skipped.
    public func parseModelList(_ stdout: String) -> [String] {
        var models: [String] = []
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" "), let slash = line.firstIndex(of: "/"),
                  slash != line.startIndex, line.index(after: slash) != line.endIndex,
                  !models.contains(line) else { continue }
            models.append(line)
        }
        return models
    }

    /// `opencode run` has no schema flag: the schema goes in the prompt (`HeadlessCommand.build`)
    /// and `SchemaRepair` gets its one resumed retry.
    public var hasNativeSchema: Bool { false }

    public func classify(error: AgentErrorSignal) -> AgentFailureKind? {
        AgentErrorVocabulary.classify(error)
    }

    // MARK: - Read-only and write isolation

    /// The two agents a headless run picks from with `--agent`, both defined by
    /// `OPENCODE_CONFIG_CONTENT` (see `environment(base:account:arguments:)`). A config-content
    /// agent wins over the same name in the person's global config AND in the project's —
    /// probed: with `agent.<name>.permission {"*":"allow"}` in both, the injected definition's
    /// tool set held.
    public static let readOnlyAgent = "flightdeck-readonly"
    public static let integratorAgent = "flightdeck-integrator"

    /// The read-only permission set. A tool whose permission is `deny` with no allow pattern is
    /// REMOVED from the model's tool list, not merely refused — probed: the run offered exactly
    /// `glob, grep, read`. `deny` rather than `ask`: under `run` an `ask` is auto-rejected and the
    /// rejection ENDS the turn without an answer, while a `deny` is a tool error the model sees
    /// and works around.
    static var readOnlyPermission: [String: Any] {
        ["*": "deny", "read": "allow", "grep": "allow", "glob": "allow", "list": "allow"]
    }

    /// The integrator's: read, plus `edit` (which also governs OpenCode's `write` tool) for files
    /// under its work dir only. OpenCode matches an edit pattern against the file's path RELATIVE
    /// TO THE GIT WORKTREE holding it, or to `/` outside any repository — probed: from a work dir
    /// under a repository at `~`, the request named `fd-oc-probe/proj/work/PWNED.md`; under
    /// `/private/tmp`, `private/tmp/…/work/PWNED.md`. An absolute pattern never matches, and
    /// `external_directory: deny` did not stop `../OUTSIDE.md` (outside a repository nothing is
    /// external). With the pattern below, a write in the work dir landed and one to its parent
    /// was denied.
    static func writePermission(workDir: URL, fileExists: (String) -> Bool) -> [String: Any] {
        var permission = readOnlyPermission
        permission["edit"] = ["*": "deny", worktreeRelativePattern(for: workDir, fileExists: fileExists): "allow"]
        return permission
    }

    /// `<dir relative to its git worktree>/*` (`*` crosses `/` in OpenCode's matcher — probed:
    /// `*PWNED.md` matched a nested path). The worktree is the nearest ancestor holding `.git`
    /// (a directory, or the file a linked worktree has), else `/`. Symlinks are resolved first,
    /// with `realpath(3)`: OpenCode reports `/tmp/…` as `private/tmp/…`, and Foundation's
    /// `resolvingSymlinksInPath` would strip that `/private` right back off (the live test caught
    /// it on a `/var/folders` work dir — the rule matched nothing and the integrator could not
    /// write its own plan).
    public static func worktreeRelativePattern(for dir: URL, fileExists: (String) -> Bool) -> String {
        let standardized = dir.standardizedFileURL.path
        let path = realpath(standardized, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? standardized
        var components = path.split(separator: "/").map(String.init)
        var root = components.count
        while root > 0 {
            let candidate = "/" + components[..<root].joined(separator: "/") + "/.git"
            if fileExists(candidate) { break }
            root -= 1
        }
        components = Array(components[root...])
        return components.isEmpty ? "*" : components.joined(separator: "/") + "/*"
    }

    /// The `OPENCODE_CONFIG_CONTENT` a headless run carries: the read-only agent, plus the
    /// integrator when `writeDir` is given.
    public static func configContent(writeDir: URL?, fileExists: (String) -> Bool) -> String {
        func agent(_ permission: [String: Any]) -> [String: Any] {
            ["mode": "primary", "description": "Flight Deck planning agent", "permission": permission]
        }
        var agents: [String: Any] = [readOnlyAgent: agent(readOnlyPermission)]
        if let writeDir { agents[integratorAgent] = agent(writePermission(workDir: writeDir, fileExists: fileExists)) }
        // A seat never shares its session to opencode.ai or swaps its own binary mid-round.
        let config: [String: Any] = ["agent": agents, "share": "disabled", "autoupdate": false]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The child's environment:
    /// - the account bound through `XDG_DATA_HOME` (nil = `base` as is: the built-in account);
    /// - `OPENCODE_DISABLE_PROJECT_CONFIG=1`, so a project's own `opencode.json` cannot re-grant
    ///   tools — probed: a project config whose `agent.build.permission` allowed everything beat
    ///   `OPENCODE_PERMISSION` outright;
    /// - `OPENCODE_DISABLE_CLAUDE_CODE=1`, so OpenCode does not load the person's `~/.claude`
    ///   CLAUDE.md and skills into a seat's prompt; autoupdate off so a seat never swaps its own
    ///   binary mid-round;
    /// - the claude child-session variables removed, as every profile removes them.
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] {
        var env = ClaudeProfile.scrubbingChildSession(base)
        env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        env["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        if let account { env[Self.homeEnvironmentKey] = account.home.path }
        return env
    }

    /// `environment(base:account:)` plus the seat agents' definitions, read off the argv
    /// `HeadlessCommand.build` produced: the integrator is defined only for a run that asks for
    /// it, with its edit rule rooted at that run's `--dir`. Read from the argv because
    /// `HeadlessCommand.environment` receives the built command, not the request — and the argv
    /// is exactly what the child will run, so the two cannot disagree.
    public func environment(base: [String: String], account: AgentAccountRef?, arguments: [String],
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String: String] {
        var env = environment(base: base, account: account)
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        let writeDir = value(after: "--agent") == Self.integratorAgent
            ? value(after: "--dir").map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
        env["OPENCODE_CONFIG_CONTENT"] = Self.configContent(writeDir: writeDir, fileExists: fileExists)
        return env
    }

    // MARK: - Output

    /// `opencode run --format json`: one JSON event per line, every one carrying `sessionID`.
    /// The answer is the text of the LAST message that has any (`text` events carry
    /// `part.messageID` and `part.text`); a tool call is its own step, so earlier messages hold
    /// the model's narration before a tool. A run that fails reports `{"type":"error",
    /// "error":{"name":…,"data":{"message":…,"statusCode":…}}}` and still exits 0 (probed with
    /// the fake model's HTTP 400), so the error event — not the exit code — is the failure.
    public static func parse(_ stdout: Data) -> (sessionID: String?, answer: String?, error: String?) {
        var session: String?, error: String?
        var lastMessage: String?, texts: [String: String] = [:]
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let s = obj["sessionID"] as? String, !s.isEmpty { session = s }
            switch obj["type"] as? String {
            case "text":
                guard let part = obj["part"] as? [String: Any], let text = part["text"] as? String,
                      let message = part["messageID"] as? String else { continue }
                texts[message, default: ""] += text
                lastMessage = message
            case "error":
                error = errorMessage(obj)
            default:
                continue
            }
        }
        return (session, lastMessage.flatMap { texts[$0] }, error)
    }

    /// The human-readable reason in an `error` event, with its HTTP status in front when it has
    /// one — so a 429 or a 401 reaches `AgentErrorVocabulary`'s phrase table even when the
    /// provider's own message names neither.
    public static func errorMessage(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "error" else { return nil }
        let error = obj["error"] as? [String: Any]
        let data = error?["data"] as? [String: Any]
        let message = data?["message"] as? String ?? error?["name"] as? String ?? "error"
        if let status = data?["statusCode"] as? Int { return "\(status) \(message)" }
        return message
    }

    /// The JSON object in a model's reply: the reply itself, or the contents of a ```json fence
    /// around it. A schema-less harness's model wraps JSON in a fence often enough that refusing
    /// it would spend the one repair on formatting.
    public static func jsonText(in answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appended to every prompt: `run` has no schema flag, so the contract is stated in words.
    public static func schemaInstruction(_ schemaJSON: String) -> String {
        "\n\nReply with ONLY one JSON object that validates against this JSON Schema — no prose, no code fence:\n"
            + schemaJSON
    }
}
