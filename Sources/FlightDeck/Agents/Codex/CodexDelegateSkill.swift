import Foundation
import IntakeKit

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
/// **The file is the user's the moment they touch it.** It lives in the user's own home, so
/// the user may edit it or delete it, and either choice has to stick. A sidecar,
/// `.flightdeck-managed`, holds the SHA-256 of the bytes Flight Deck last wrote:
/// - A file that still hashes to that value is ours, and is refreshed when the app ships new
///   text.
/// - A file that hashes to anything else was edited, and is left alone.
/// - A sidecar with no file beside it means the user deleted the file, which is never undone.
/// - A file with no sidecar is the user's own and is left alone. The exception is a file
///   whose bytes equal ours exactly; it is adopted, since nothing the user wrote can be lost.
///
/// The mechanics now live in `CodexBundledSkill`, which copies a skill folder; this enum keeps
/// the single-file `delegate` entry points its callers and tests use.
///
/// **The directory is prefixed.** A user skill named `delegate` in the same home must never be
/// overwritten; `flightdeck-delegate` is Flight Deck's own name and nothing else's.
enum CodexDelegateSkill {
    static let directoryName = CodexBundledSkill.delegate.directoryName
    static let sidecarName = CodexBundledSkill.sidecarName

    typealias Outcome = CodexBundledSkill.Outcome

    private static let skill = CodexBundledSkill.delegate

    /// The bundled skill file, or nil when `bundle` does not carry the plugin (under
    /// `scripts/test-unit.sh`, `Bundle.main` is the xctest tool, which never does).
    static func bundledSource(bundle: Bundle) -> URL? {
        skill.bundledSource(bundle: bundle)?.appendingPathComponent(CodexBundledSkill.skillFile)
    }

    static func destination(codexHome: URL) -> URL {
        skill.directory(codexHome: codexHome).appendingPathComponent(CodexBundledSkill.skillFile)
    }

    static func sidecar(codexHome: URL) -> URL { skill.sidecar(codexHome: codexHome) }

    static func digest(_ data: Data) -> String { CodexBundledSkill.digest(data) }

    /// Installs the single file at `source` as the skill's `SKILL.md`.
    static func install(from source: URL, codexHome: URL) throws -> Outcome {
        try skill.install(
            entries: [.init(path: CodexBundledSkill.skillFile, data: try Data(contentsOf: source))],
            codexHome: codexHome)
    }

    @discardableResult
    static func uninstall(home codexHome: URL) throws -> Bool { try skill.uninstall(home: codexHome) }

    /// The home a transport with no explicit one inherits, resolved the way codex itself does:
    /// `CODEX_HOME`, then `~/.codex`.
    static func resolvedHome(_ home: URL?) -> URL {
        home
            ?? ProcessInfo.processInfo.environment[CodexProfile.homeEnvironmentKey]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentID.codex.builtInHome
    }

    /// Installs just this skill through the shared off-main, bounded entry point.
    static func installBundledOffMainActor(
        codexHome home: URL?,
        bundle: Bundle = .main,
        timeoutSeconds: Double = 2,
        debugBuild: Bool = SessionDaemon.isDebugBuild,
        perform: @escaping @Sendable (URL, URL) throws -> Outcome = install(from:codexHome:)
    ) async {
        await CodexBundledSkill.installOffMainActor(
            skills: [skill], codexHome: home, bundle: bundle, timeoutSeconds: timeoutSeconds,
            debugBuild: debugBuild,
            perform: { _, folder, home in
                try perform(folder.appendingPathComponent(CodexBundledSkill.skillFile), home)
            })
    }
}
