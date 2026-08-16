import Foundation

/// One `claude` option Flight Deck models with a control.
struct FlagSpec: Equatable {
    /// How the flag's value is written, and therefore how its control renders.
    enum Kind: Equatable {
        /// Bare presence: `--verbose`.
        case toggle
        /// Presence or explicit negation: `--chrome` / `--no-chrome`.
        case negatable(off: String)
        /// A fixed set of values. `allowsCustom` adds a "Custom…" entry with a text
        /// field — `--effort` is closed, but `--model` takes any full model name and
        /// `--autocompact` takes `auto` or a token count.
        case choice([String], allowsCustom: Bool)
        /// A flag whose argument may be omitted: `--debug [filter]`, `--worktree [name]`.
        case optionalValue
        /// A single required argument.
        case string
        /// A single required argument edited in a multi-line field.
        case multiline
        /// A single required argument that is a filesystem path (adds a Choose… button).
        case path
        /// Repeatable or variadic: `--add-dir a b`.
        case list
    }

    enum Section: String, CaseIterable {
        case modelEffort = "Model & Effort"
        case permissionsTools = "Permissions & Tools"
        case contextPrompts = "Context & Prompts"
        case mcpPlugins = "MCP & Plugins"
        case integrations = "Integrations"
        case troubleshooting = "Troubleshooting"
    }

    let canonical: String
    let aliases: [String]
    let kind: Kind
    let section: Section
    let label: String
    let help: String

    init(
        _ canonical: String,
        aliases: [String] = [],
        kind: Kind,
        section: Section,
        label: String,
        help: String
    ) {
        self.canonical = canonical
        self.aliases = aliases
        self.kind = kind
        self.section = section
        self.label = label
        self.help = help
    }
}

/// The options Flight Deck models, as a snapshot of `claude --help` taken 2026-08-11.
///
/// Deliberately excluded: `--print`-only options (`--output-format`, `--json-schema`,
/// `--max-budget-usd`, `--fallback-model`, `--include-partial-messages`,
/// `--replay-user-messages`, `--forward-subagent-text`, `--include-hook-events`,
/// `--no-session-persistence`, `--input-format`) and session-identity options that
/// collide with Flight Deck's own management (`--continue`, `--resume`, `--from-pr`,
/// `--teleport`, `--cloud`, `--bg`, `--environment`, `--file`, `--fork-session`).
/// They stay reachable through passthrough — excluded from the catalog is not forbidden.
enum ClaudeFlagCatalog {
    /// Owned by Flight Deck and never user-editable: the session id binds the transcript
    /// watcher, and the name is driven by sidebar rename.
    static let appManaged: Set<String> = ["--session-id", "--name", "-n"]

    static let all: [FlagSpec] = [
        // MARK: Model & Effort
        .init("--model", kind: .choice(["fable", "opus", "sonnet", "haiku"], allowsCustom: true),
              section: .modelEffort, label: "Model",
              help: "Alias for the latest model, or a full model name."),
        .init("--effort", kind: .choice(["low", "medium", "high", "xhigh", "max"], allowsCustom: false),
              section: .modelEffort, label: "Effort",
              help: "Reasoning effort level for the session."),
        .init("--autocompact", kind: .choice(["auto"], allowsCustom: true),
              section: .modelEffort, label: "Auto-compact",
              help: "Auto-compact window size: auto, or 100k–1M tokens."),

        // MARK: Permissions & Tools
        .init("--permission-mode",
              kind: .choice(["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"],
                            allowsCustom: false),
              section: .permissionsTools, label: "Permission mode",
              help: "How Claude asks before acting."),
        .init("--dangerously-skip-permissions", kind: .toggle,
              section: .permissionsTools, label: "Skip all permission checks",
              help: "Bypasses every permission check. Recommended only for sandboxes with no internet access."),
        .init("--allow-dangerously-skip-permissions", kind: .toggle,
              section: .permissionsTools, label: "Allow skipping permission checks",
              help: "Makes bypassing available without enabling it by default."),
        .init("--tools", kind: .list,
              section: .permissionsTools, label: "Available tools",
              help: #"Built-in tools to expose. "" disables all; "default" uses all."#),
        .init("--allowedTools", aliases: ["--allowed-tools"], kind: .list,
              section: .permissionsTools, label: "Allowed tools",
              help: #"Tools allowed without asking, e.g. "Bash(git *)" Edit."#),
        .init("--disallowedTools", aliases: ["--disallowed-tools"], kind: .list,
              section: .permissionsTools, label: "Disallowed tools",
              help: "Tools to deny outright."),
        .init("--disable-slash-commands", kind: .toggle,
              section: .permissionsTools, label: "Disable all skills",
              help: "Turns off slash commands and skills."),

        // MARK: Context & Prompts
        .init("--system-prompt", kind: .multiline,
              section: .contextPrompts, label: "System prompt",
              help: "Replaces the default system prompt."),
        .init("--append-system-prompt", kind: .multiline,
              section: .contextPrompts, label: "Append to system prompt",
              help: "Appended to the default system prompt."),
        .init("--add-dir", kind: .list,
              section: .contextPrompts, label: "Additional directories",
              help: "Extra directories tools may access."),
        .init("--agent", kind: .string,
              section: .contextPrompts, label: "Agent",
              help: "Agent for the session; overrides the 'agent' setting."),
        .init("--exclude-dynamic-system-prompt-sections", kind: .toggle,
              section: .contextPrompts, label: "Exclude dynamic prompt sections",
              help: "Moves per-machine sections into the first user message, improving cache reuse."),

        // MARK: MCP & Plugins
        .init("--mcp-config", kind: .list,
              section: .mcpPlugins, label: "MCP config",
              help: "Load MCP servers from JSON files or strings."),
        .init("--strict-mcp-config", kind: .toggle,
              section: .mcpPlugins, label: "Strict MCP config",
              help: "Use only servers from MCP config, ignoring all other MCP configuration."),
        .init("--plugin-dir", kind: .list,
              section: .mcpPlugins, label: "Plugin directories",
              help: "Load plugins from directories or .zip files, for this session only."),
        .init("--plugin-url", kind: .list,
              section: .mcpPlugins, label: "Plugin URLs",
              help: "Fetch plugin .zip files from URLs, for this session only."),
        .init("--settings", kind: .string,
              section: .mcpPlugins, label: "Settings",
              help: "Path to a settings JSON file, or a JSON string."),
        .init("--setting-sources", kind: .string,
              section: .mcpPlugins, label: "Setting sources",
              help: "Comma-separated list: user, project, local."),

        // MARK: Integrations
        .init("--ide", kind: .toggle,
              section: .integrations, label: "Connect to IDE",
              help: "Connect to an IDE on startup when exactly one valid IDE is available."),
        .init("--chrome", kind: .negatable(off: "--no-chrome"),
              section: .integrations, label: "Claude in Chrome",
              help: "Enable or disable the Chrome integration."),
        .init("--remote-control", kind: .optionalValue,
              section: .integrations, label: "Remote Control",
              help: "Start with Remote Control enabled, optionally named."),
        .init("--remote-control-session-name-prefix", kind: .string,
              section: .integrations, label: "Remote Control name prefix",
              help: "Prefix for auto-generated Remote Control session names."),
        .init("--worktree", aliases: ["-w"], kind: .optionalValue,
              section: .integrations, label: "Git worktree",
              help: "Create a new git worktree for the session, optionally named. claude then runs in the worktree rather than the project root; the tab stays filed under its project."),
        .init("--tmux", kind: .toggle,
              section: .integrations, label: "tmux session",
              help: "Create a tmux session for the worktree. Requires a worktree."),
        .init("--brief", kind: .toggle,
              section: .integrations, label: "Agent-to-user messages",
              help: "Enable the SendUserMessage tool."),
        .init("--prompt-suggestions", kind: .optionalValue,
              section: .integrations, label: "Prompt suggestions",
              help: "Enable prompt suggestions."),

        // MARK: Troubleshooting
        .init("--bare", kind: .toggle,
              section: .troubleshooting, label: "Bare mode",
              help: "Skip hooks, LSP, plugin sync, auto-memory, and CLAUDE.md auto-discovery."),
        .init("--safe-mode", kind: .toggle,
              section: .troubleshooting, label: "Safe mode",
              help: "Start with all customizations disabled. Useful for troubleshooting a broken configuration."),
        .init("--verbose", kind: .toggle,
              section: .troubleshooting, label: "Verbose",
              help: "Override the verbose-mode setting."),
        .init("--debug", aliases: ["-d"], kind: .optionalValue,
              section: .troubleshooting, label: "Debug",
              help: #"Debug mode, optionally filtered, e.g. "api,hooks"."#),
        .init("--debug-file", kind: .path,
              section: .troubleshooting, label: "Debug log file",
              help: "Write debug logs to this path. Implicitly enables debug mode."),
        .init("--ax-screen-reader", kind: .toggle,
              section: .troubleshooting, label: "Screen-reader output",
              help: "Flat text, no decorative borders or animations."),
        .init("--betas", kind: .list,
              section: .troubleshooting, label: "Beta headers",
              help: "Beta headers to include in API requests (API-key users only)."),
    ]

    /// Resolves a canonical name, an alias, or a negatable flag's off-form.
    static func spec(for name: String) -> FlagSpec? {
        byName[name]
    }

    private static let byName: [String: FlagSpec] = {
        var table: [String: FlagSpec] = [:]
        for spec in all {
            table[spec.canonical] = spec
            for alias in spec.aliases { table[alias] = spec }
            if case .negatable(let off) = spec.kind { table[off] = spec }
        }
        return table
    }()
}
