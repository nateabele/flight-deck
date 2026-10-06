import CryptoKit
import Foundation

/// Decides which running claude tabs must be sent `/reload-plugins` so they see a plugin that
/// changed under them, such as the `delegate` skill arriving with an app update.
///
/// **Why it is needed (probe P1, docs/DELEGATION-PROBES.md, Claude Code 2.1.289).** A skill
/// added to a `--plugin-dir` plugin after the session started never appeared, not even 8 s
/// later; `/reload-plugins` made it appear at once without a model turn. Under fd-abduco a tab's
/// claude outlives an app swap, and its `--plugin-dir` still names the same bundle path, whose
/// contents just changed. So every tab adopted from a previous app run is stale exactly when
/// the bundled plugin's bytes differ from what that run shipped.
///
/// **What it deliberately is not.** It types nothing. The caller is `SessionStore`, through its
/// existing gated `inject`, which refuses a dialog and an unreadable screen. That gate admits a
/// busy composer, though, and whether claude runs a `/reload-plugins` queued mid-turn as a
/// command is unprobed. So the caller asks only while the tab is idle.
struct PluginReload {
    static let command = "/reload-plugins"

    /// The `UserDefaults` key holding the plugin fingerprint the previous app run of this
    /// build shipped. Per build because Debug and Release share one defaults domain but not
    /// tabs or plugin bytes: one key would read every switch between the two as a plugin
    /// change, and reload every adopted tab of the build launched next for nothing.
    static func fingerprintDefaultsKey(debug: Bool = SessionDaemon.isDebugBuild) -> String {
        debug ? "ClaudePluginFingerprint.Debug" : "ClaudePluginFingerprint"
    }

    /// Tabs that still need the command. A `Set` because each tab needs it once, however many
    /// registry ticks find it idle before the injection lands.
    private(set) var pending: Set<UUID>

    /// `adopted` are the tabs whose claude was already running when this app run started.
    /// A tab this run launches loads the current plugin itself, and never belongs here.
    init(adopted: some Sequence<UUID>, pluginChanged: Bool) {
        pending = pluginChanged ? Set(adopted) : []
    }

    func needsReload(_ id: UUID) -> Bool { pending.contains(id) }

    /// Called from `inject`'s `onSent`, never before: a drive that unwound typed nothing, and
    /// the tab must stay pending so the next idle tick retries it.
    mutating func sent(_ id: UUID) { pending.remove(id) }

    /// A relaunched or closed tab no longer has a stale claude to reload.
    mutating func forget(_ id: UUID) { pending.remove(id) }

    /// A digest of every file under the plugin: path and bytes. A skill, hook script or
    /// manifest change all count, since `/reload-plugins` is what picks up any of them.
    /// Returns nil when the directory cannot be read, which callers treat as "no change" so that
    /// an unreadable bundle never makes every tab reload on every launch.
    static func fingerprint(of directory: URL) -> String? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        let files = walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { url -> (path: String, url: URL) in
                let full = url.resolvingSymlinksInPath().path
                return (String(full.dropFirst(root.path.count)), url)
            }
            .sorted { $0.path < $1.path }
        var hash = SHA256()
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { return nil }
            // Each length is framed in, so moving bytes from one file into its neighbour
            // changes the digest rather than hashing to the same concatenation.
            hash.update(data: Data("\(file.path)\u{0}\(data.count)\u{0}".utf8))
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `current` differs from what the previous app run recorded. It also records
    /// `current` for the next run. A missing record counts as changed: the first run that
    /// ships this check follows a build whose tabs never had the skill.
    ///
    /// The record is written up front, not after every tab is reloaded, so a crash before
    /// then costs those tabs their reload until the next plugin change. A tab can always be
    /// relaunched, and a record that waited on every tab would re-reload on every launch
    /// while any one of them stayed busy.
    static func pluginChanged(current: String?, defaults: UserDefaults,
                              debug: Bool = SessionDaemon.isDebugBuild) -> Bool {
        guard let current else { return false }
        let key = fingerprintDefaultsKey(debug: debug)
        let previous = defaults.string(forKey: key)
        defaults.set(current, forKey: key)
        return previous != current
    }
}
