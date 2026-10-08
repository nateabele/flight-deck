import CryptoKit
import Foundation
import IntakeKit
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
/// **The directory is prefixed.** A user skill named `delegate` in the same home must never be
/// overwritten; `flightdeck-delegate` is Flight Deck's own name and nothing else's.
enum CodexDelegateSkill {
    static let directoryName = "flightdeck-delegate"
    static let sidecarName = ".flightdeck-managed"

    /// What one `install` did. Each case names a branch a test pins, because the wrong branch
    /// either clobbers a user's edit or resurrects a file they deleted.
    enum Outcome: Equatable {
        case installed, refreshed, adopted, current, userEdited, userDeleted, userOwned
    }

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

    static func sidecar(codexHome: URL) -> URL {
        destination(codexHome: codexHome).deletingLastPathComponent().appendingPathComponent(sidecarName)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func install(from source: URL, codexHome: URL) throws -> Outcome {
        let ours = try Data(contentsOf: source)
        let target = destination(codexHome: codexHome)
        let onDisk = try? Data(contentsOf: target)
        let recorded = (try? String(contentsOf: sidecar(codexHome: codexHome), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (onDisk, recorded) {
        case (nil, nil):
            try write(ours, codexHome: codexHome)
            return .installed
        case (nil, _?):
            return .userDeleted
        case (let disk?, nil):
            guard disk == ours else { return .userOwned }
            try writeSidecar(for: ours, codexHome: codexHome)
            return .adopted
        case (let disk?, let hash?):
            // Equal bytes are checked before the hash. This also heals a crash between the two
            // writes in `write`: SKILL.md is written first, so an interrupted refresh leaves our
            // exact bytes beside a stale sidecar, and that must read as ours, not as an edit.
            if disk == ours {
                if hash != digest(ours) { try writeSidecar(for: ours, codexHome: codexHome) }
                return .current
            }
            guard digest(disk) == hash else { return .userEdited }
            try write(ours, codexHome: codexHome)
            return .refreshed
        }
    }

    /// Removes the skill only while it is still Flight Deck's. Returns whether anything was
    /// removed. An edited or adopted-elsewhere file stays; a lone sidecar (the user already
    /// deleted SKILL.md) is cleared, so a later install starts fresh.
    @discardableResult
    static func uninstall(home codexHome: URL) throws -> Bool {
        let target = destination(codexHome: codexHome)
        let marker = sidecar(codexHome: codexHome)
        guard let hash = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let fm = FileManager.default
        if let disk = try? Data(contentsOf: target) {
            guard digest(disk) == hash else { return false }
            try fm.removeItem(at: target)
        }
        try fm.removeItem(at: marker)
        let directory = target.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try fm.removeItem(at: directory)
        }
        return true
    }

    private static func write(_ data: Data, codexHome: URL) throws {
        let target = destination(codexHome: codexHome)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
        try writeSidecar(for: data, codexHome: codexHome)
    }

    private static func writeSidecar(for data: Data, codexHome: URL) throws {
        try Data((digest(data) + "\n").utf8).write(to: sidecar(codexHome: codexHome), options: .atomic)
    }

    /// The home a transport with no explicit one inherits, resolved the way codex itself does:
    /// `CODEX_HOME`, then `~/.codex`.
    static func resolvedHome(_ home: URL?) -> URL {
        home
            ?? ProcessInfo.processInfo.environment[CodexProfile.homeEnvironmentKey]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentID.codex.builtInHome
    }

    /// The production entry point. `SessionStore.startCodex` awaits it just before an account's
    /// app-server is spawned. The codex tabs of that account run under the same `CODEX_HOME`,
    /// so they see the skill when their TUI starts. It never throws: a missing skill costs the
    /// agent one capability, while a failed spawn would cost the user the whole tab.
    ///
    /// **Off the main actor, and bounded.** It is disk I/O in a user-controlled directory, and
    /// `CODEX_HOME` can sit on a network volume that stalls. `startCodex`'s task is memoized
    /// per account, so a stall here would wedge every codex creation on the account, not just
    /// this one. That is the same reason `CodexVersionProbe.checkOffMainActor` races a deadline.
    /// The copy is detached and raced rather than awaited structurally, because blocking file
    /// I/O cannot be cancelled. A copy that loses the race finishes on its own thread, and a
    /// late copy is harmless.
    ///
    /// **Not from a Debug build.** A codex home is the user's real one (`~/.codex`, or an
    /// account's own), shared with their installed Flight Deck. A Debug build writing there
    /// would put a development copy of the skill in front of every codex tab the release app
    /// runs, and its sidecar would then read the release copy as the user's own edit, so the
    /// release app would never refresh it again. Logged once, so a developer testing the
    /// skill knows why it is missing.
    static func installBundledOffMainActor(
        codexHome home: URL?,
        bundle: Bundle = .main,
        timeoutSeconds: Double = 2,
        debugBuild: Bool = SessionDaemon.isDebugBuild,
        perform: @escaping @Sendable (URL, URL) throws -> Outcome = install(from:codexHome:)
    ) async {
        guard !debugBuild else {
            if !loggedDebugSkip.swap(true) {
                logger.info("a Debug build does not install the delegate skill into a codex home; use a Release build to test it")
            }
            return
        }
        guard let source = bundledSource(bundle: bundle) else { return }
        let codexHome = resolvedHome(home)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task.detached {
                do {
                    let outcome = try perform(source, codexHome)
                    logger.info("delegate skill in \(codexHome.path, privacy: .public): \(String(describing: outcome), privacy: .public)")
                } catch {
                    logger.error("could not install the delegate skill into \(codexHome.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                once.resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                once.resume()
            }
        }
    }

    private static let loggedDebugSkip = OnceFlag()

    /// Set once, from any thread: `installBundledOffMainActor` runs per codex account.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        /// Sets the flag and returns what it was.
        func swap(_ new: Bool) -> Bool { lock.withLock { defer { value = new }; return value } }
    }

    /// Resumes its continuation exactly once, whichever of the copy or the deadline gets there
    /// first. Resuming a continuation twice is a crash.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func resume() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }
}
