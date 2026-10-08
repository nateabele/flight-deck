import Foundation

/// xAI's `grok` CLI ("Grok Build"), as a headless planning harness (grok/gemini spec §3.0).
///
/// Every fact below was read off grok 1.0.30 (`grok --help`, the docs it ships under
/// `~/.grok/docs/user-guide/`, and its string table) on 2026-10-07; the ones marked "probed"
/// were also exercised against a signed-in account (spec §10). grok auto-updates, so a comment
/// here is pinned to that version, never to "grok".
public struct GrokProfile: AgentProfile {
    public init() {}
    public var id: AgentID { .grok }
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

    /// FALLBACKS ONLY, and they go stale: the model list and default are read from `grok models`
    /// at detection (`parseModelList`, default first). These are what that printed for a
    /// SuperGrok account on 2026-10-07 — where the default had already moved from grok-4.6 to
    /// grok-4.7 since the spec was written — and are used only when the list can't be read. Effort levels are the TUI's `/effort` menu (`low`, `medium`, `high`,
    /// `xhigh`); the CLI also knows `none`/`minimal`/`max`, but "a model only accepts the levels
    /// its menu advertises", so offering them would let a seat pick one grok-4.6 rejects.
    ///
    /// The default effort is `medium`, not the `high` claude and codex start at: at high, the
    /// first live round's grok reviewer took 763 s (52k of 56k output tokens spent thinking),
    /// five times the next-slowest seat, and every round pays that. The maintainer's ruling of
    /// 2026-10-07; any agent can still be set to `high` in the Rounds editor.
    public var modelCatalog: ProfileModelCatalog {
        ProfileModelCatalog(aliases: ["grok-4.7", "grok-4.7-build-fast", "grok-4.6"], listArguments: ["models"],
                            defaultPlanningModel: "grok-4.7", defaultPlanningEffort: "medium",
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
    /// any auth banner above it) never becomes a second entry. The `(default)` model is moved
    /// FIRST: detection seeds a new seat with `first`, so the account's own default wins over
    /// this profile's hard-coded one.
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
            if rest.hasSuffix("(default)") { models.insert(id, at: 0) } else { models.append(id) }
        }
        return models
    }

    /// `--json-schema` constrains the final answer (validated by grok against the schema, with
    /// a bounded retry that ends in `error_max_structured_output_retries`).
    public var hasNativeSchema: Bool { true }

    /// grok's error spellings live in the one shared table (`AgentErrorVocabulary`), with
    /// claude's and codex's — a copy here would drift from it the way the old four lists did.
    public func classify(error: AgentErrorSignal) -> AgentFailureKind? {
        AgentErrorVocabulary.classify(error)
    }

    /// Variables that stop grok reading ANOTHER CLI's config: grok scans `~/.claude`,
    /// `~/.cursor` and `~/.codex` (hooks, MCP servers, rules, skills, CLAUDE.md) by default
    /// (`compat.*`). Defense in depth only — `environment` also moves `HOME`, which is what
    /// actually holds (see there). `GROK_MEMORY=0` keeps cross-session memory from leaking one
    /// seat's plan into another's prompt; the autoupdater is off so a seat never swaps its own
    /// binary mid-round.
    /// The variable that relocates everything grok keeps — its login (`auth.json`), config and
    /// sessions — so it is what binds an account. `environment` also moves `HOME` there; see why.
    public static let homeEnvironmentKey = "GROK_HOME"

    public static let isolationEnvironment: [String: String] = {
        var env = ["GROK_MEMORY": "0", "GROK_DISABLE_AUTOUPDATER": "1"]
        for vendor in ["CLAUDE", "CURSOR", "CODEX"] {
            for surface in ["HOOKS", "MCPS", "RULES", "SKILLS", "AGENTS"] { env["GROK_\(vendor)_\(surface)_ENABLED"] = "0" }
        }
        return env
    }()

    /// The child's environment. Two bindings, both to the grok home (`account.home`, else an
    /// explicit `GROK_HOME` in `base`, else `$HOME/.grok`):
    /// - `GROK_HOME` relocates everything grok keeps — `auth.json` (the login, a plain file,
    ///   not the Keychain), config, sessions — so it is what bills an account;
    /// - `HOME` points there too. Probed on grok 1.0.30, 2026-10-07: with the `compat.*`
    ///   variables alone, `grok inspect` still listed the operator's Claude Code PLUGINS as
    ///   enabled — superpowers, plannotator and codex — with their hooks, which grok discovers
    ///   under `~/.claude/plugins` on a path no compat switch covers. Those hooks would inject
    ///   superpowers' instructions into every seat and run codex's 900 s Stop review gate. With
    ///   `HOME` moved to the grok home (which has no `.claude`, `.claude.json` or `.codex`),
    ///   the same `inspect` listed no plugins, no MCP servers and no hooks, and `grok models`
    ///   still read the login. grok's own built-in skills still load; they are prompts only.
    /// Nothing is carried over from `~/.grok/config.toml`: proxies reach grok through the
    /// environment (`HTTPS_PROXY` & co., already in `base`), and this machine's config sets no
    /// endpoint (2026-10-07). The claude child-session variables are dropped like every
    /// profile drops them, so nothing grok spawns inherits them.
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] {
        var env = ClaudeProfile.scrubbingChildSession(base)
        env.merge(Self.isolationEnvironment) { _, isolation in isolation }
        let grokHome = account?.home.path ?? base["GROK_HOME"] ?? base["HOME"].map { ($0 as NSString).appendingPathComponent(".grok") }
        if let grokHome {
            env["GROK_HOME"] = grokHome
            env["HOME"] = grokHome
        }
        return env
    }
}
