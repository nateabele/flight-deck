import Foundation
import os

/// Delivers Flight Deck's `delegate` skill to codex through codex's own skill loader: a copy
/// of the bundled `SKILL.md` at `<CODEX_HOME>/skills/flightdeck-delegate/SKILL.md`.
///
/// **Why a copy into the account's home, and not `developer_instructions`.** Probe P2
/// (docs/DELEGATION-PROBES.md, codex-cli 0.160.0 and 0.153.4) found that codex scans exactly
/// four roots for SKILL.md skills: `<repo>/.agents/skills`, `<repo>/.codex/skills`,
/// `$CODEX_HOME/skills` and `~/.agents/skills`. A fifth root can be added only with the
/// app-server's `skills/extraRoots/set` RPC, and a codex tab is its own `codex resume` TUI
/// process, which that RPC never reaches. No `-c` key registers a skill path either. The
/// fallback, `-c developer_instructions=…`, was measured to REPLACE a `developer_instructions`
/// the user set in `config.toml`. It is not appended, so it would silently delete the user's
/// own instructions from every codex tab. A skill in `$CODEX_HOME/skills` is additive.
/// Codex also lists it in the request as name, description and path, and loads the body only
/// when the model opens it, which is the same on-demand shape the Claude plugin gives it.
///
/// **One source of truth.** The bytes come from the Claude plugin's own
/// `skills/delegate/SKILL.md` inside the app bundle. Nothing here holds skill text, so the two
/// agents cannot drift apart.
///
/// **The directory is prefixed.** A user skill named `delegate` in the same home must never be
/// overwritten; `flightdeck-delegate` is Flight Deck's own name and nothing else's.
enum CodexDelegateSkill {
    static let directoryName = "flightdeck-delegate"

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "codex")

    /// The bundled skill file, or nil when `bundle` does not carry the plugin (under
    /// `scripts/test-unit.sh`, `Bundle.main` is the xctest tool, which never does).
    static func bundledSource(bundle: Bundle) -> URL? {
        guard let source = ClaudePluginLocation.directory(bundle: bundle)?
            .appendingPathComponent("skills/delegate/SKILL.md"),
              FileManager.default.fileExists(atPath: source.path)
        else { return nil }
        return source
    }

    static func destination(codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    /// Writes the skill only when the copy is missing or differs, and returns whether it wrote.
    /// It compares bytes rather than skipping whenever a file exists, so an app update that
    /// changes the skill reaches codex on the next spawn rather than never.
    @discardableResult
    static func install(from source: URL, codexHome: URL) throws -> Bool {
        let data = try Data(contentsOf: source)
        let target = destination(codexHome: codexHome)
        if (try? Data(contentsOf: target)) == data { return false }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
        return true
    }

    /// The production entry point, called just before an account's app-server is spawned.
    /// The codex tabs of that account run under the same `CODEX_HOME`, so they see the skill
    /// when their TUI starts. It never throws: a missing skill costs the agent one capability,
    /// while a failed spawn would cost the user the whole tab.
    ///
    /// `home` is nil for a transport that inherits Flight Deck's own environment, and that
    /// resolves the way codex itself would: `CODEX_HOME`, then `~/.codex`.
    static func installBundled(codexHome home: URL?, bundle: Bundle = .main) {
        guard let source = bundledSource(bundle: bundle) else { return }
        let codexHome = home
            ?? ProcessInfo.processInfo.environment[AgentID.codex.homeEnvironmentKey]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentID.codex.builtInHome
        do {
            if try install(from: source, codexHome: codexHome) {
                logger.info("installed the delegate skill into \(codexHome.path, privacy: .public)")
            }
        } catch {
            logger.error("could not install the delegate skill into \(codexHome.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
