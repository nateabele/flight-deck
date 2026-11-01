import Foundation
import os

/// Drops, at launch, the variables an agent's tool call leaves behind when it relaunches the app.
///
/// Why this exists: `open` hands the launched app its caller's environment. When an agent — a
/// codex exec, a claude Bash call, often inside a Flight Deck tab — relaunches the app after a
/// build, the app inherits that call's whole environment, and every tab launched after it
/// inherits it in turn. Codex sets `NO_COLOR=1` for its commands, so every claude tab came up
/// black and white (2026-10-24); the same leak hands each tab another tab's
/// `CLAUDE_CODE_SESSION_ID`, `FLIGHT_DECK_SESSION_ID` and `CLAUDE_CONFIG_DIR`, and a
/// `GIT_EDITOR=true` that makes `git commit` in a plain shell tab skip the editor.
///
/// Only an agent-launched app is touched: a Dock or Finder launch carries none of the markers,
/// and a `NO_COLOR` the user set in launchd is theirs to keep.
enum LaunchEnvironment {
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "environment")

    /// Variables only an agent's tool call, or a Flight Deck tab, would have set.
    static let markers: Set<String> = [
        "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID", "FLIGHT_DECK_SESSION_ID", "AI_AGENT",
    ]

    /// Dropped by prefix: session identity from claude, codex and Flight Deck's own tabs.
    static let prefixes = ["CLAUDE_CODE_", "CODEX_", "FLIGHT_DECK_", "FLIGHTDECK_"]

    /// Dropped by name: the rest of what claude, codex and a Flight Deck tab inject.
    static let names: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_PLUGIN_DATA", "CLAUDE_PLUGIN_ROOT",
        "CLAUDE_CONFIG_DIR", "AI_AGENT", "FD_OUTLOG_BUDGET",
        "NO_COLOR", "GIT_EDITOR", "GIT_PAGER", "GH_PAGER",
    ]

    /// The variables to unset: none unless a marker shows an agent launched the app.
    static func strays(in environment: [String: String]) -> [String] {
        guard !markers.isDisjoint(with: environment.keys) else { return [] }
        return environment.keys
            .filter { key in names.contains(key) || prefixes.contains { key.hasPrefix($0) } }
            .sorted()
    }

    /// Applies `strays` to this process. Call before any thread starts — `unsetenv` races a
    /// reader of `environ` the same way `LaunchLocale`'s `setenv` does.
    static func scrubProcessEnvironment() {
        for key in strays(in: ProcessInfo.processInfo.environment) {
            unsetenv(key)
            logger.info("unset \(key, privacy: .public): inherited from an agent's launch")
        }
    }
}
