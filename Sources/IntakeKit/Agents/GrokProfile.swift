import Foundation

/// xAI's `grok` CLI ("Grok Build"), as a headless planning harness (grok/gemini spec §3.0).
///
/// Every fact below was read off grok 1.0.30 (`grok --help`, the docs it ships under
/// `~/.grok/docs/user-guide/`, and its string table) on 2026-10-07; the ones marked "probed"
/// were also exercised against a signed-in account (spec §10). grok auto-updates, so a comment
/// here is pinned to that version, never to "grok".
public struct GrokProfile: AgentProfile {
    public init() {}
    public var id: Harness { .grok }
    public var family: ModelFamily { .grok }
    public var binaryName: String { "grok" }

    /// `grok models` reads the cached login and never calls a model, so it costs no tokens.
    /// Signed out it still EXITS 0 and still prints the model list — only its first line, "You
    /// are not authenticated.", tells the two apart (grok 1.0.30). So the exit code alone would
    /// offer a signed-out grok, and the round would only fail later; the predicate keys on that
    /// line, and also wants a parsable model list so an unrelated `grok` on PATH (or a stub
    /// script) that prints nothing never reads as signed in.
    public var signInCheck: SignInCheck {
        SignInCheck(arguments: ["models"], signedOutHint: "Grok: run `grok login`") { output in
            let text = (output.stdout + "\n" + output.stderr).lowercased()
            return output.exitCode == 0 && !text.contains("not authenticated")
                && !GrokProfile().parseModelList(output.stdout).isEmpty
        }
    }

    /// `grok-4.6` is the CLI's own default and `grok-4.5` the only other model on a SuperGrok
    /// account (`grok models`, 2026-10-07); they double as the picker's list when the runtime
    /// list can't be read. Effort levels are the TUI's `/effort` menu (`low`, `medium`, `high`,
    /// `xhigh`); the CLI also knows `none`/`minimal`/`max`, but "a model only accepts the levels
    /// its menu advertises", so offering them would let a seat pick one grok-4.6 rejects.
    public var modelCatalog: ProfileModelCatalog {
        ProfileModelCatalog(aliases: ["grok-4.6", "grok-4.5"], listArguments: ["models"],
                            defaultPlanningModel: "grok-4.6", defaultPlanningEffort: "high",
                            effortValues: ["low", "medium", "high", "xhigh"])
    }

    /// `grok models` prints a header, then one model per line, bulleted `*` (the default, also
    /// suffixed ` (default)`) or `-`:
    ///
    ///     Default model: grok-4.6
    ///
    ///     Available models:
    ///       * grok-4.6 (default)
    ///       - grok-4.5
    ///
    /// Only bulleted lines AFTER "Available models:" count, so the "Default model:" line (and
    /// any auth banner above it) never becomes a second entry.
    public func parseModelList(_ stdout: String) -> [String] {
        var models: [String] = []
        var inList = false
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("available models") { inList = true; continue }
            guard inList, let bullet = line.first, bullet == "*" || bullet == "-" else { continue }
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let id = rest.split(separator: " ").first.map(String.init), !id.isEmpty,
                  !models.contains(id) else { continue }
            models.append(id)
        }
        return models
    }

    /// `--json-schema` constrains the final answer (validated by grok against the schema, with
    /// a bounded retry that ends in `error_max_structured_output_retries`).
    public var hasNativeSchema: Bool { true }

    /// grok's own error spellings, from its 1.0.30 string table. Usage limits come first: on a
    /// SuperGrok plan they are the likely real failure (a weekly shared pool), and several of
    /// them ("You hit your weekly limit.") say neither "rate" nor "429", so the generic
    /// classifier would call them a harness error and send the human to retry into the same
    /// wall. "403" is deliberately absent — grok uses it for both credit exhaustion and
    /// permission errors, and guessing wrong either way sends the human to the wrong fix.
    public func classify(error: AgentErrorSignal) -> AgentFailureKind? {
        let text: String
        switch error {
        case .stderr(let s): text = s
        case .streamErrorEvent(let json): text = Self.errorText(ofEvent: json)
        case .transcriptAPIError(let kind): text = kind
        case .appServerError(let code, let message): text = (code.map { "status \($0) " } ?? "") + message
        }
        let t = text.lowercased()
        if Self.rateLimitSpellings.contains(where: t.contains) { return .rateLimited }
        if Self.authSpellings.contains(where: t.contains) { return .authExpired }
        if Self.overloadSpellings.contains(where: t.contains) { return .overloaded }
        return nil
    }

    static let rateLimitSpellings = [
        "rate limit", "weekly limit", "usage limit", "free usage limit", "credit limit", "out of credits",
        "usage balance exhausted", "spending limit", "too many requests", "payment required",
        "status 429", "status 402", "429",
    ]
    static let authSpellings = [
        "not authenticated", "not signed in", "authentication required", "session has expired", "credentials were rejected",
        "authentication could not be refreshed", "no oauth2 configuration", "grok login", "unauthorized", "401",
    ]
    static let overloadSpellings = [
        "service unavailable", "overloaded", "bad gateway", "gateway timeout", "status 503", "status 502", "status 529",
    ]

    /// The human-readable part of one grok error event: `{"type":"error","message":…}`, or a
    /// `result` flagged `is_error` (its `errors[]`, then `result`, then `subtype`). Falls back
    /// to the raw text, so a shape nobody has seen yet is still matched rather than dropped.
    static func errorText(ofEvent json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return json }
        var parts: [String] = []
        if let message = obj["message"] as? String { parts.append(message) }
        for e in obj["errors"] as? [Any] ?? [] {
            if let s = e as? String { parts.append(s) }
            else if let d = e as? [String: Any], let m = d["message"] as? String { parts.append(m) }
        }
        if let result = obj["result"] as? String { parts.append(result) }
        if let subtype = obj["subtype"] as? String { parts.append(subtype) }
        return parts.isEmpty ? json : parts.joined(separator: "\n")
    }

    /// Variables that stop grok reading ANOTHER CLI's config. grok scans `~/.claude` and
    /// `~/.cursor` (hooks, MCP servers, rules, skills, CLAUDE.md) by default (`compat.claude.*`,
    /// `compat.cursor.*`), and a fresh `GROK_HOME` does not stop it — so without these a
    /// "read-only" planning seat would run the operator's Claude Code hooks (which execute
    /// arbitrary commands and fail OPEN) and start their MCP servers, whose mutators write
    /// anywhere. CLAUDE.md is dropped with them: the operator's global one is written to steer
    /// their own sessions, not a planning seat; the project's AGENTS.md still loads.
    /// `GROK_MEMORY=0` keeps cross-session memory from leaking one seat's plan into another's
    /// prompt; the autoupdater is off so a seat never swaps its own binary mid-round.
    public static let isolationEnvironment: [String: String] = [
        "GROK_CLAUDE_HOOKS_ENABLED": "0", "GROK_CLAUDE_MCPS_ENABLED": "0", "GROK_CLAUDE_RULES_ENABLED": "0",
        "GROK_CLAUDE_SKILLS_ENABLED": "0", "GROK_CLAUDE_AGENTS_ENABLED": "0",
        "GROK_CURSOR_HOOKS_ENABLED": "0", "GROK_CURSOR_MCPS_ENABLED": "0", "GROK_CURSOR_RULES_ENABLED": "0",
        "GROK_CURSOR_SKILLS_ENABLED": "0", "GROK_CURSOR_AGENTS_ENABLED": "0",
        "GROK_MEMORY": "0", "GROK_DISABLE_AUTOUPDATER": "1",
    ]

    /// `GROK_HOME` relocates everything grok keeps — `auth.json` (the login, a plain file, not
    /// the Keychain), config, sessions — so pointing it at an account's home is what bills that
    /// account. nil leaves the operator's own `~/.grok`. Nothing is carried over from
    /// `~/.grok/config.toml`: proxies reach grok through the environment (`HTTPS_PROXY` & co.,
    /// which `base` already holds), and this machine's config sets no endpoint (2026-10-07).
    /// The claude child-session variables are dropped like every profile drops them: they mean
    /// nothing to grok, and must not reach anything grok spawns.
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] {
        var env = base
        for key in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"] { env.removeValue(forKey: key) }
        env.merge(Self.isolationEnvironment) { _, isolation in isolation }
        if let account { env["GROK_HOME"] = account.home.path }
        return env
    }
}
