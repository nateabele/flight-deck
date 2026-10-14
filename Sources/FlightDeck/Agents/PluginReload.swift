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
/// **Only when the user comes back to the tab.** A stale tab is reloaded the first time it is
/// activated (selected, with the app frontmost) after the plugin changed, not all at once at
/// launch. Typing into every background tab at launch reached tabs that were asleep or not on
/// screen, and there the Return was sometimes lost: the command stayed in the box, and the next
/// launch's kill-and-yank put it back behind a second copy (`/reload-plugins/reload-plugins`).
/// So `stale` is persisted across runs, a tab leaves it only once the box reads empty after the
/// command, and a tab whose Return was lost waits for its next activation, not the next tick.
///
/// **What it deliberately is not.** It types nothing. The caller is `SessionStore`, through its
/// existing gated `inject`, which refuses a dialog and an unreadable screen. That gate admits a
/// busy composer, though, and claude queues a slash command typed mid-turn as a message
/// (probed against 2.1.300). So the caller asks only while the tab is idle.
///
/// **It must not look like work.** Measured against Claude Code 2.1.293: the command flips the
/// tab's registry row to `busy` for about 90 ms and back to `idle`. A poll that lands inside
/// that blip reads it as a finished turn, which marks the tab unread and resets its "active N
/// min ago". The store typed the command into a tab it knew was idle, so it owns that blip:
/// `sent` opens a short quiet window, and `masks` names the idle/busy edges inside it that the
/// store must not stamp or mark. The window is a safety bound, not the signal. A busy spell
/// that outlives it is real work and goes through as usual.
struct PluginReload {
    static let command = "/reload-plugins"

    /// How long after the command a tab's idle/busy edges count as the reload's own. About
    /// fifty times the measured blip; most blips fall between polls and are never seen at all.
    static let quietWindow: TimeInterval = 5

    /// The `UserDefaults` key holding the plugin fingerprint the previous app run of this
    /// build shipped. Per build because Debug and Release share one defaults domain but not
    /// tabs or plugin bytes: one key would read every switch between the two as a plugin
    /// change, and reload every adopted tab of the build launched next for nothing.
    static func fingerprintDefaultsKey(debug: Bool = SessionDaemon.isDebugBuild) -> String {
        debug ? "ClaudePluginFingerprint.Debug" : "ClaudePluginFingerprint"
    }

    /// The `UserDefaults` key holding `stale`, so a tab not activated before the app quits is
    /// still reloaded when it is activated in a later run. Per build for the fingerprint's reason.
    static func staleTabsDefaultsKey(debug: Bool = SessionDaemon.isDebugBuild) -> String {
        debug ? "ClaudePluginStaleTabs.Debug" : "ClaudePluginStaleTabs"
    }

    /// Tabs whose claude loaded the plugin before its last change and has not reloaded since.
    private(set) var stale: Set<UUID>

    /// Tabs already tried during the current activation. A lost Return is not retried until the
    /// user activates the tab again, so a tab whose Return keeps failing is never typed into on
    /// every tick.
    private(set) var tried: Set<UUID> = []

    /// Tabs whose command is typed but whose box has not been read back yet.
    private(set) var checking: Set<UUID> = []

    /// Tabs whose reload blip may still be on its way, with when the quiet window closes.
    private(set) var quietUntil: [UUID: Date] = [:]

    /// `adopted` are the tabs whose claude was already running when this app run started.
    /// A tab this run launches loads the current plugin itself, and never belongs here.
    /// `stillStale` is the previous run's `stale`: an adopted tab in it has run the old plugin
    /// since before that run, and still does.
    init(adopted: some Sequence<UUID>, pluginChanged: Bool, stillStale: some Sequence<UUID> = []) {
        let adopted = Set(adopted)
        stale = pluginChanged ? adopted : adopted.intersection(stillStale)
    }

    func needsReload(_ id: UUID) -> Bool {
        stale.contains(id) && !tried.contains(id) && !checking.contains(id)
    }

    /// The user activated a tab: one that was tried and failed may be tried again.
    mutating func activated() { tried.removeAll() }

    /// Called from `inject`'s `onSent`, never before: a drive that unwound typed nothing, and
    /// the tab must stay due so the next idle tick retries it.
    mutating func sent(_ id: UUID, at now: Date) {
        tried.insert(id)
        checking.insert(id)
        quietUntil[id] = now.addingTimeInterval(Self.quietWindow)
    }

    /// The box was read back after the command. `submitted` is false when the command was
    /// still sitting in it.
    mutating func checked(_ id: UUID, submitted: Bool) {
        checking.remove(id)
        if submitted { stale.remove(id) }
    }

    /// A relaunched or closed tab no longer has a stale claude to reload.
    mutating func forget(_ id: UUID) {
        stale.remove(id)
        tried.remove(id)
        checking.remove(id)
        quietUntil.removeValue(forKey: id)
    }

    /// What a composer holds after a lost Return, with every leading copy of the command
    /// removed: the draft the kill-and-yank put back behind it, or "" if there was none. Nil
    /// when the box does not start with the command, which means it was submitted.
    static func leftover(in draft: String) -> String? {
        var rest = Substring(draft)
        guard rest.hasPrefix(command) else { return nil }
        while rest.hasPrefix(command) {
            rest = rest.dropFirst(command.count).drop { $0 == " " }
        }
        return String(rest)
    }

    /// Whether this edge is the reload's own blip: idle to busy or busy to idle, inside the
    /// tab's quiet window. A `waiting` edge is never masked, since a dialog wants the user.
    func masks(_ id: UUID, from old: SessionActivity?, to new: SessionActivity?, now: Date) -> Bool {
        guard let until = quietUntil[id], now < until else { return false }
        let blip: Set<SessionActivity?> = [.idle, .busy]
        return old != new && blip.contains(old) && blip.contains(new)
    }

    /// Closes the windows this tick finished: the blip landed back on idle, the tab reached
    /// something other than idle or busy, or the window ran out.
    mutating func settle(_ transitions: [StatusTransition], now: Date) {
        for transition in transitions where quietUntil[transition.id] != nil {
            switch transition.new?.activity {
            case .busy: continue
            case .idle: if transition.old?.activity == .busy { quietUntil.removeValue(forKey: transition.id) }
            case .waiting, nil: quietUntil.removeValue(forKey: transition.id)
            }
        }
        quietUntil = quietUntil.filter { now < $0.value }
    }

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
    /// The record is written up front, not after every tab is reloaded: the tabs still owed a
    /// reload carry over in `staleTabs` instead, which the store saves as soon as it arms.
    static func pluginChanged(current: String?, defaults: UserDefaults,
                              debug: Bool = SessionDaemon.isDebugBuild) -> Bool {
        guard let current else { return false }
        let key = fingerprintDefaultsKey(debug: debug)
        let previous = defaults.string(forKey: key)
        defaults.set(current, forKey: key)
        return previous != current
    }

    /// The previous run's `stale`. Unparseable entries are dropped.
    static func staleTabs(in defaults: UserDefaults, debug: Bool = SessionDaemon.isDebugBuild) -> Set<UUID> {
        Set((defaults.stringArray(forKey: staleTabsDefaultsKey(debug: debug)) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func recordStale(_ tabs: Set<UUID>, in defaults: UserDefaults,
                            debug: Bool = SessionDaemon.isDebugBuild) {
        defaults.set(tabs.map(\.uuidString).sorted(), forKey: staleTabsDefaultsKey(debug: debug))
    }
}
