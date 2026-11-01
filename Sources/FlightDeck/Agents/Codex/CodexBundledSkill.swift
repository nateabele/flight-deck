import CryptoKit
import Foundation
import os

/// Delivers one of Flight Deck's bundled skills to codex through codex's own skill loader: a copy
/// of the plugin's `skills/<name>/` FOLDER at `<CODEX_HOME>/skills/flightdeck-<name>/`.
///
/// **Why a copy into the account's home** is documented on `CodexDelegateSkill`: codex scans four
/// fixed roots for skills, no flag adds a fifth, and `developer_instructions` would replace the
/// user's own. A skill in `$CODEX_HOME/skills` is additive.
///
/// **One source of truth.** The bytes come from the Claude plugin's own `skills/<name>/` folder
/// inside the app bundle, so the two agents cannot drift apart. A skill may carry more than
/// `SKILL.md` (the visual-provider skill ships `templates/`), so the whole folder is copied.
///
/// **The folder is the user's the moment they touch any file in it.** A sidecar,
/// `.flightdeck-managed`, holds the digest of the files Flight Deck last wrote:
/// - A folder that still hashes to that value is ours, and is refreshed when the app ships new
///   text. Files the new version no longer ships are removed with it.
/// - A folder that hashes to anything else (an edit, or a file the user added) is left whole.
/// - A sidecar with no `SKILL.md` beside it means the user deleted the skill, never undone.
/// - A `SKILL.md` with no sidecar is the user's own. The exception is a folder whose files equal
///   ours exactly; it is adopted, since nothing the user wrote can be lost.
///
/// **The digest of a lone `SKILL.md` is the plain SHA-256 of its bytes.** That is what every
/// install made before folders existed recorded, and what the sidecar of an installed `delegate`
/// skill still says; a different format would read every existing install as the user's edit.
/// Any other folder hashes sorted relative paths, each followed by NUL, its length and its bytes.
///
/// **The directory is prefixed.** A user skill named `delegate` in the same home must never be
/// overwritten; `flightdeck-delegate` is Flight Deck's own name and nothing else's.
struct CodexBundledSkill: Sendable, Equatable {
    static let sidecarName = ".flightdeck-managed"
    static let skillFile = "SKILL.md"

    static let delegate = CodexBundledSkill(name: "delegate")
    static let peerMessaging = CodexBundledSkill(name: "peer-messaging")
    static let visualProvider = CodexBundledSkill(name: "visual-provider")

    /// What one `install` did. Each case names a branch a test pins, because the wrong branch
    /// either clobbers a user's edit or resurrects a file they deleted.
    enum Outcome: Equatable {
        case installed, refreshed, adopted, current, userEdited, userDeleted, userOwned
    }

    /// One file of a skill: a path relative to the skill folder, and its bytes.
    struct Entry: Equatable {
        let path: String
        let data: Data
    }

    let name: String

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "codex")

    var directoryName: String { "flightdeck-\(name)" }

    func directory(codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    func sidecar(codexHome: URL) -> URL {
        directory(codexHome: codexHome).appendingPathComponent(Self.sidecarName)
    }

    /// The bundled skill folder, or nil when `bundle` does not carry the plugin (under
    /// `scripts/test-unit.sh`, `Bundle.main` is the xctest tool, which never does).
    func bundledSource(bundle: Bundle) -> URL? {
        guard let folder = ClaudePluginLocation.directory(bundle: bundle)?
            .appendingPathComponent("skills/\(name)", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.skillFile).path)
        else { return nil }
        return folder
    }

    // MARK: - Digest

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ entries: [Entry]) -> String {
        if entries.count == 1, let only = entries.first, only.path == skillFile { return digest(only.data) }
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(entry.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(entry.data.count).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: entry.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every regular file under `folder`, by relative path. Finder's `.DS_Store` and the sidecar
    /// are not part of a skill.
    static func entries(in folder: URL) throws -> [Entry] {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in walker {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  url.lastPathComponent != ".DS_Store", url.lastPathComponent != sidecarName
            else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            entries.append(Entry(path: path, data: try Data(contentsOf: url)))
        }
        return entries.sorted { $0.path < $1.path }
    }

    // MARK: - Install

    func install(from source: URL, codexHome: URL) throws -> Outcome {
        try install(entries: Self.entries(in: source), codexHome: codexHome)
    }

    func install(entries ours: [Entry], codexHome: URL) throws -> Outcome {
        let ourDigest = Self.digest(ours)
        let folder = directory(codexHome: codexHome)
        let onDisk: [Entry]? = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.skillFile).path)
            ? try Self.entries(in: folder) : nil
        let recorded = (try? String(contentsOf: sidecar(codexHome: codexHome), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (onDisk, recorded) {
        case (nil, nil):
            try write(ours, codexHome: codexHome, replacing: [])
            return .installed
        case (nil, _?):
            return .userDeleted
        case (let disk?, nil):
            guard Self.digest(disk) == ourDigest else { return .userOwned }
            try writeSidecar(ourDigest, codexHome: codexHome)
            return .adopted
        case (let disk?, let hash?):
            // Equal bytes are checked before the hash. This also heals a crash between the two
            // writes in `write`: the files are written first, so an interrupted refresh leaves
            // our exact bytes beside a stale sidecar, and that must read as ours, not as an edit.
            let diskDigest = Self.digest(disk)
            if diskDigest == ourDigest {
                if hash != ourDigest { try writeSidecar(ourDigest, codexHome: codexHome) }
                return .current
            }
            guard diskDigest == hash else { return .userEdited }
            try write(ours, codexHome: codexHome, replacing: disk)
            return .refreshed
        }
    }

    /// Removes the skill only while it is still Flight Deck's. Returns whether anything was
    /// removed. An edited folder stays; a lone sidecar (the user already deleted SKILL.md) is
    /// cleared, so a later install starts fresh.
    @discardableResult
    func uninstall(home codexHome: URL) throws -> Bool {
        let folder = directory(codexHome: codexHome)
        let marker = sidecar(codexHome: codexHome)
        guard let hash = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(Self.skillFile).path) {
            guard Self.digest(try Self.entries(in: folder)) == hash else { return false }
            try fm.removeItem(at: folder)
            return true
        }
        try fm.removeItem(at: marker)
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try fm.removeItem(at: folder) }
        return true
    }

    private func write(_ entries: [Entry], codexHome: URL, replacing old: [Entry]) throws {
        let fm = FileManager.default
        let folder = directory(codexHome: codexHome)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries {
            let target = folder.appendingPathComponent(entry.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: target, options: .atomic)
        }
        // Only files this app wrote earlier (`old` matched the sidecar) are removed; a first
        // install never deletes anything.
        let kept = Set(entries.map(\.path))
        for stale in old where !kept.contains(stale.path) {
            try? fm.removeItem(at: folder.appendingPathComponent(stale.path))
        }
        try writeSidecar(Self.digest(entries), codexHome: codexHome)
    }

    private func writeSidecar(_ digest: String, codexHome: URL) throws {
        try Data((digest + "\n").utf8).write(to: sidecar(codexHome: codexHome), options: .atomic)
    }

    // MARK: - Production entry point

    /// The production entry point. `SessionStore.startCodex` awaits it just before an account's
    /// app-server is spawned. The codex tabs of that account run under the same `CODEX_HOME`,
    /// so they see the skills when their TUI starts. It never throws: a missing skill costs the
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
    /// would put a development copy of a skill in front of every codex tab the release app
    /// runs, and its sidecar would then read the release copy as the user's own edit, so the
    /// release app would never refresh it again. Logged once, so a developer testing a skill
    /// knows why it is missing.
    static func installOffMainActor(
        skills: [CodexBundledSkill],
        codexHome home: URL?,
        bundle: Bundle = .main,
        timeoutSeconds: Double = 2,
        debugBuild: Bool = SessionDaemon.isDebugBuild,
        perform: @escaping @Sendable (CodexBundledSkill, URL, URL) throws -> Outcome = { skill, source, home in
            try skill.install(from: source, codexHome: home)
        }
    ) async {
        guard !debugBuild else {
            if !loggedDebugSkip.swap(true) {
                logger.info("a Debug build does not install bundled skills into a codex home; use a Release build to test them")
            }
            return
        }
        let sources = skills.compactMap { skill in skill.bundledSource(bundle: bundle).map { (skill, $0) } }
        guard !sources.isEmpty else { return }
        let codexHome = CodexDelegateSkill.resolvedHome(home)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task.detached {
                for (skill, source) in sources {
                    do {
                        let outcome = try perform(skill, source, codexHome)
                        logger.info("\(skill.name, privacy: .public) skill in \(codexHome.path, privacy: .public): \(String(describing: outcome), privacy: .public)")
                    } catch {
                        logger.error("could not install the \(skill.name, privacy: .public) skill into \(codexHome.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
                once.resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                once.resume()
            }
        }
    }

    private static let loggedDebugSkip = OnceFlag()

    /// Set once, from any thread: `installOffMainActor` runs per codex account.
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
