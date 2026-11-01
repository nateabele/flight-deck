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
/// - A folder that hashes to anything else (an edit, a file the user added, a planted link) is
///   left whole. Editor and tool junk (`.DS_Store`, `__pycache__`, `.git`, `*.swp`) does not count.
/// - A skill folder that is itself a link is never touched, and no link is ever followed. A
///   refresh is staged in a sibling folder and swapped in, so it is all old or all new.
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
        /// The skill folder is a link or a file. Nothing was written, and nothing is ever written through it.
        case unsafe
    }

    /// One file of a skill: a path relative to the skill folder, and its bytes.
    struct Entry: Equatable {
        let path: String
        let data: Data
        /// A symbolic link (or other non-regular node): `data` is its destination.
        var isLink = false
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
        if entries.count == 1, let only = entries.first, only.path == skillFile, !only.isLink {
            return digest(only.data)
        }
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(entry.path.utf8))
            hasher.update(data: Data([0, entry.isLink ? 76 : 70, 0]))
            hasher.update(data: Data(String(entry.data.count).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: entry.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Names that tools and editors leave in a folder without the user having meant to change
    /// the skill. They never count as an edit, at any depth.
    static func isJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name == "__pycache__" || name == ".git" || name.hasSuffix(".swp")
    }

    /// What `path` is, read with `lstat` semantics: a link is reported as a link, never followed.
    enum NodeKind { case missing, directory, file, link, other }

    static func kind(of url: URL) -> NodeKind {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        else { return .missing }
        switch type {
        case .typeDirectory: return .directory
        case .typeRegular: return .file
        case .typeSymbolicLink: return .link
        default: return .other
        }
    }

    /// Every file under `folder`, by relative path, walked without following any link. A link
    /// is an entry of its own (`isLink`, its destination as the data) so it counts in the
    /// digest. Junk and the top-level sidecar are not part of a skill. `allowLinks: false` is
    /// for the bundled source, which must never contain one.
    static func entries(in folder: URL, allowLinks: Bool = true) throws -> [Entry] {
        var entries: [Entry] = []
        func walk(_ directory: URL, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                if isJunk(name) || (prefix.isEmpty && name == sidecarName) { continue }
                let url = directory.appendingPathComponent(name)
                let path = prefix + name
                switch kind(of: url) {
                case .directory: try walk(url, path + "/")
                case .file: entries.append(Entry(path: path, data: try Data(contentsOf: url)))
                case .link:
                    guard allowLinks else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                    entries.append(Entry(path: path, data: Data(destination.utf8), isLink: true))
                case .other:
                    entries.append(Entry(path: path, data: Data("other".utf8), isLink: true))
                case .missing: continue
                }
            }
        }
        try walk(folder, "")
        return entries
    }

    // MARK: - Install

    func install(from source: URL, codexHome: URL) throws -> Outcome {
        try install(entries: Self.entries(in: source, allowLinks: false), codexHome: codexHome)
    }

    /// `stageFault` is a test seam: it is called after each staged file with the count so far,
    /// and may throw to model a crash part-way through a refresh.
    func install(entries ours: [Entry], codexHome: URL,
                 stageFault: ((Int) throws -> Void)? = nil) throws -> Outcome {
        let ourDigest = Self.digest(ours)
        let folder = directory(codexHome: codexHome)
        switch Self.kind(of: folder) {
        case .link, .file, .other:
            Self.logger.error("\(folder.path, privacy: .public) is not a plain folder (a link or a file); the \(name, privacy: .public) skill was not installed")
            return .unsafe
        case .missing, .directory: break
        }
        removeStaging(codexHome: codexHome)
        let existing = Self.kind(of: folder) == .directory ? try Self.entries(in: folder) : []
        let onDisk: [Entry]? = existing.contains { $0.path == Self.skillFile && !$0.isLink } ? existing : nil
        let recorded = (try? String(contentsOf: sidecar(codexHome: codexHome), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (onDisk, recorded) {
        case (nil, nil):
            // A folder with other content and no SKILL.md is not ours to replace.
            guard existing.isEmpty else { return .userOwned }
            try publish(ours, codexHome: codexHome, stageFault: stageFault)
            return .installed
        case (nil, _?):
            return .userDeleted
        case (let disk?, nil):
            guard Self.digest(disk) == ourDigest else { return .userOwned }
            try writeSidecar(ourDigest, codexHome: codexHome)
            return .adopted
        case (let disk?, let hash?):
            // A folder that already equals the bundled files is ours whatever the sidecar says.
            // That heals a crash right after a swap, and a sidecar written by another version.
            let diskDigest = Self.digest(disk)
            if diskDigest == ourDigest {
                if hash != ourDigest { try writeSidecar(ourDigest, codexHome: codexHome) }
                return .current
            }
            guard diskDigest == hash else { return .userEdited }
            try publish(ours, codexHome: codexHome, stageFault: stageFault)
            return .refreshed
        }
    }

    /// Removes the skill only while it is still Flight Deck's. Returns whether anything was
    /// removed. An edited folder stays; a lone sidecar (the user already deleted SKILL.md) is
    /// cleared, so a later install starts fresh. A folder that is a link is never touched.
    @discardableResult
    func uninstall(home codexHome: URL) throws -> Bool {
        let folder = directory(codexHome: codexHome)
        let marker = sidecar(codexHome: codexHome)
        guard Self.kind(of: folder) == .directory,
              let hash = (try? String(contentsOf: marker, encoding: .utf8))?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let fm = FileManager.default
        let existing = try Self.entries(in: folder)
        if existing.contains(where: { $0.path == Self.skillFile && !$0.isLink }) {
            guard Self.digest(existing) == hash else { return false }
            try fm.removeItem(at: folder)
            return true
        }
        try fm.removeItem(at: marker)
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try fm.removeItem(at: folder) }
        return true
    }

    private func stagingPrefix() -> String { ".flightdeck-\(name).staging-" }

    /// Staging folders a crashed refresh left beside the skill. They are Flight Deck's by name.
    private func removeStaging(codexHome: URL) {
        let skills = directory(codexHome: codexHome).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skills.path)) ?? []
        for stale in names where stale.hasPrefix(stagingPrefix()) {
            try? FileManager.default.removeItem(at: skills.appendingPathComponent(stale))
        }
    }

    /// Writes the whole skill, sidecar included, into a fresh sibling folder and swaps it in, so
    /// the skill is the old folder or the new one and never a mix. Nothing is written through the
    /// installed folder, so a link planted inside it is never followed; a swap replaces the link.
    private func publish(_ entries: [Entry], codexHome: URL, stageFault: ((Int) throws -> Void)?) throws {
        let fm = FileManager.default
        let folder = directory(codexHome: codexHome)
        let stage = folder.deletingLastPathComponent().appendingPathComponent(stagingPrefix() + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var written = 0
        for entry in entries {
            let target = stage.appendingPathComponent(entry.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: target)
            written += 1
            try stageFault?(written)
        }
        try Data((Self.digest(entries) + "\n").utf8).write(to: stage.appendingPathComponent(Self.sidecarName))
        if Self.kind(of: folder) == .missing {
            guard rename(stage.path, folder.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else if renamex_np(stage.path, folder.path, UInt32(RENAME_SWAP)) != 0 {
            // No atomic swap on this volume: move the old folder aside, then the new one in.
            let aside = stage.deletingLastPathComponent().appendingPathComponent(stagingPrefix() + "old-" + UUID().uuidString)
            try fm.moveItem(at: folder, to: aside)
            do { try fm.moveItem(at: stage, to: folder) } catch {
                try? fm.moveItem(at: aside, to: folder)
                throw error
            }
            try? fm.removeItem(at: aside)
        }
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
