import Foundation

/// The shell and environment new sessions are spawned into.
struct ShellPreferences: Codable, Equatable {
    /// nil means "use `$SHELL`", which is `ShellResolver`'s existing behaviour.
    var shellOverride: String?
    /// Extra variables merged into every new session's environment.
    var environment: [String: String]
    /// Blanks an inherited `CLAUDE_CODE_CHILD_SESSION`. Claude Code sets that marker for
    /// nested sessions, and it turns transcript saving off — which silently kills the
    /// sidebar's inbound rename sync, since the watcher tails a file that is never
    /// written. See docs/FOLLOWUPS.md. Defaults on.
    var clearChildSessionMarker: Bool

    init(
        shellOverride: String? = nil,
        environment: [String: String] = [:],
        clearChildSessionMarker: Bool = true
    ) {
        self.shellOverride = shellOverride
        self.environment = environment
        self.clearChildSessionMarker = clearChildSessionMarker
    }
}

/// Alerts the user has chosen to stop seeing.
struct ConfirmationPreferences: Codable, Equatable {
    /// Set by the "Don't ask me again" box on the project-close alert.
    var suppressProjectClose: Bool

    init(suppressProjectClose: Bool = false) {
        self.suppressProjectClose = suppressProjectClose
    }
}

/// Session-lifecycle behaviour, edited on the Claude tab.
///
/// Every field added here must be Optional or carry a custom decoder, for the reason given
/// on `Preferences.claude`: users already have `"claude": {...}` blobs on disk, and a
/// non-optional field with no default would fail to decode every one of them.
struct ClaudePreferences: Codable, Equatable {
    /// Sessions that were mid-turn when Flight Deck last went away are prompted to continue
    /// once they have resumed and settled. Off by default: picking work back up unattended
    /// is a decision the user has to make deliberately, not one to inherit from an upgrade.
    var autoResumeRunningSessions: Bool

    init(autoResumeRunningSessions: Bool = false) {
        self.autoResumeRunningSessions = autoResumeRunningSessions
    }
}

/// Everything the Preferences window edits.
struct Preferences: Codable, Equatable {
    var globalFlags: FlagSet
    /// Keyed by standardized project path. Kept here rather than on `Repo` because an
    /// override outlives the project it belongs to — closing a project removes it from
    /// `SessionStore` entirely.
    var projectFlags: [String: FlagSet]
    var shell: ShellPreferences
    /// Optional, and it has to stay that way. `UserDefaultsPreferencesPersistence.load()`
    /// decodes with `try?`, and synthesized `Codable` throws on a missing key rather than
    /// falling back to a property default — so a non-optional field here would fail to
    /// decode every existing `preferences.v1` blob and silently reset every flag, override
    /// and shell setting the user has. `nil` means "never answered", which is not suppressed.
    var confirmations: ConfirmationPreferences?
    /// Optional for exactly the reason `confirmations` is — see that property's comment.
    /// `nil` means "never configured", which reads as every field's default.
    var claude: ClaudePreferences?

    init(
        globalFlags: FlagSet = FlagSet(),
        projectFlags: [String: FlagSet] = [:],
        shell: ShellPreferences = ShellPreferences(),
        confirmations: ConfirmationPreferences? = nil,
        claude: ClaudePreferences? = nil
    ) {
        self.globalFlags = globalFlags
        self.projectFlags = projectFlags
        self.shell = shell
        self.confirmations = confirmations
        self.claude = claude
    }
}
