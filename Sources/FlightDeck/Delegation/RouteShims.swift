import CoreServices
import Foundation
import HostKit

/// Transparent routing (spec §8): a per-session directory at the front of the tab's `PATH`
/// holding one symlink per command a `[[route]]` names, each pointing at the bundled
/// `flightdeck-route-shim.sh`. Typing `xcodebuild test …` in the tab then runs the shim, which
/// hands the argv to `flightdeck route-exec`; the CLI matches it and delegates it or execs the
/// real binary.
///
/// **Symlinks to one bundled script, not generated scripts.** Each shim learns its command
/// from `$0`, so the shim directory carries no logic that an app update could leave stale: a
/// new script reaches every running tab the moment the bundle is replaced.
///
/// **Per session, not per project.** A tab's `PATH` is fixed at launch, so its directory must
/// outlive any one config; keying it on the session lets a tab close remove exactly its own.
/// The contents are the project's, which is why the watcher below rebuilds every session of a
/// project together.
struct RouteShims {
    /// Spec §8: set in a tab to run every routed command locally. Any value but empty or `0`,
    /// in the shim and the CLI alike (`CLIRunner.bypassesRouting`).
    static let bypassVariable = "FLIGHTDECK_NO_ROUTE"
    /// The CLI the shim should run. Whatever `flightdeck` is first on a tab's PATH is often an
    /// older install with no `route-exec`, which broke every routed command; naming this
    /// build's own CLI at launch removes the guess.
    static let cliVariable = "FLIGHTDECK_CLI"

    /// Where session directories live: `<state dir>/route-shims/<session id>/`.
    let root: URL
    /// The script every shim links to.
    let script: URL

    /// The copy inside the app bundle (`Contents/Resources/RouteShim/`, a folder reference in
    /// `project.yml`). Nil only in a bundle built without it, where routing is simply absent.
    static func bundledScript(_ bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "flightdeck-route-shim", withExtension: "sh", subdirectory: "RouteShim")
    }

    /// `Contents/MacOS/flightdeck` in this app's bundle.
    static func bundledCLI(_ bundle: Bundle = .main) -> URL? {
        bundle.url(forAuxiliaryExecutable: "flightdeck")
    }

    static func defaultRoot(stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("route-shims", isDirectory: true)
    }

    func directory(for session: UUID) -> URL {
        root.appendingPathComponent(session.uuidString, isDirectory: true)
    }

    /// Brings `session`'s directory in line with `projectRoot`'s `delegate.toml`, and returns
    /// the command names now shimmed.
    ///
    /// Returns nil, changing nothing, when the file does not parse. A config is invalid for a
    /// moment in the middle of most edits; dropping the shims then would make a routed command
    /// silently run locally, while keeping them lets `route-exec` report the parse error.
    @discardableResult
    func rebuild(session: UUID, projectRoot: URL) -> [String]? {
        let names: [String]
        do {
            let config = try DelegateConfigParser.load(projectRoot: projectRoot)?.config ?? DelegateConfig()
            names = RouteMatcher(config: config).commandNames
        } catch {
            return nil
        }
        do {
            try install(names, session: session)
        } catch {
            return nil
        }
        return names
    }

    /// Makes the directory hold exactly one link per name, each pointing at `script`.
    /// Everything in the directory is ours, so anything else is removed.
    func install(_ names: [String], session: UUID) throws {
        let fm = FileManager.default
        let dir = directory(for: session)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let wanted = Set(names)
        for existing in try fm.contentsOfDirectory(atPath: dir.path) {
            let path = dir.appendingPathComponent(existing).path
            if wanted.contains(existing), (try? fm.destinationOfSymbolicLink(atPath: path)) == script.path {
                continue
            }
            try fm.removeItem(atPath: path)
        }
        for name in names where !fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try fm.createSymbolicLink(
                atPath: dir.appendingPathComponent(name).path, withDestinationPath: script.path)
        }
    }

    /// On tab close. Best effort: a leftover directory is a few dangling symlinks under the
    /// state dir, not a fault worth surfacing.
    func remove(session: UUID) {
        try? FileManager.default.removeItem(at: directory(for: session))
    }

    /// `environment` with `dir` first on `PATH`, once, and `FLIGHTDECK_CLI` naming `cli`.
    /// With no `PATH` of its own the tab would inherit the app's, so that is what the shim
    /// directory goes in front of; setting `PATH` to the shim directory alone would leave the
    /// tab unable to find anything.
    static func environment(
        _ environment: [String: String], prepending dir: URL, cli: URL? = bundledCLI(),
        inherited: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String: String] {
        var result = environment
        if let cli { result[cliVariable] = cli.path }
        let current = environment["PATH"] ?? inherited ?? ""
        let entries = current.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard entries.first != dir.path else { return result }
        result["PATH"] = current.isEmpty
            ? dir.path : ([dir.path] + entries.filter { $0 != dir.path }).joined(separator: ":")
        return result
    }

    /// Saves the user's own `ZDOTDIR` while zsh runs Flight Deck's wrapper dotfiles.
    static let userZDOTDIRVariable = "FLIGHTDECK_USER_ZDOTDIR"
    /// What `XDG_DATA_DIRS` means when it is unset (the XDG base-directory spec's default, and
    /// what fish falls back to), kept behind ours so setting it hides no vendor directory.
    static let defaultDataDirs = "/usr/local/share:/usr/share"

    /// `Contents/Resources/RouteShim/`: the shim script and, beside it, one snippet per shell.
    var integration: URL { script.deletingLastPathComponent() }

    /// `environment` with each shell pointed at the snippet that keeps the shim directory first
    /// on `PATH` after its startup files have run (the snippets under `Resources/RouteShim/`).
    ///
    /// **Why `environment(prepending:)` is not enough.** A tab's shell is a login shell, and
    /// its startup files rebuild `PATH` in front of what it was launched with: macOS's
    /// `path_helper` puts `/etc/paths` first, and every `PATH=/x:$PATH` in a dotfile goes
    /// first too. Measured, the shim directory ended up 40th of 43 entries under fish and 18th
    /// under zsh, so a routed command ran the real binary and never reached its shim. Only the
    /// shell can put it back, after those files:
    /// - **fish** reads `<dir>/fish/vendor_conf.d/*.fish` for each `XDG_DATA_DIRS` entry.
    /// - **zsh** reads its dotfiles from `ZDOTDIR`; ours source the user's (`ZDOTDIR` saved as
    ///   `FLIGHTDECK_USER_ZDOTDIR`) and hand `ZDOTDIR` back after the last one.
    /// - **bash** has neither, so `PROMPT_COMMAND` runs ours before every prompt.
    ///
    /// Idempotent, like `environment(prepending:)`: a second pass changes nothing.
    static func shellIntegration(
        _ environment: [String: String], integration: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = environment
        func current(_ key: String) -> String? { environment[key] ?? inherited[key] }

        let dataDirs = current("XDG_DATA_DIRS").flatMap { $0.isEmpty ? nil : $0 } ?? defaultDataDirs
        if !dataDirs.split(separator: ":").contains(Substring(integration.path)) {
            result["XDG_DATA_DIRS"] = integration.path + ":" + dataDirs
        }

        let zsh = integration.appendingPathComponent("zsh", isDirectory: true).path
        if current("ZDOTDIR") != zsh {
            // Unset stays unset: the wrapper then reads the user's files from `$HOME`, as zsh would.
            if let user = current("ZDOTDIR") { result[userZDOTDIRVariable] = user }
            result["ZDOTDIR"] = zsh
        }

        let bash = ". " + shellQuote(integration.appendingPathComponent("bash/flightdeck-route-shim.bash").path)
        let prompt = current("PROMPT_COMMAND") ?? ""
        if !prompt.contains(bash) { result["PROMPT_COMMAND"] = prompt.isEmpty ? bash : bash + "; " + prompt }
        return result
    }

    /// Single-quoted for a POSIX shell: the bundle's path has a space in it.
    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Calls `onChange` when anything under a project's `.flightdeck/` changes, so its sessions'
/// shim directories can be rebuilt (spec §8: "rebuilt when `delegate.toml` changes").
///
/// **It watches the project root, not `.flightdeck/`.** FSEvents reports nothing for a watched
/// path that does not exist when the stream starts — measured with a probe stream on a temp
/// directory, not assumed — and most projects have no `.flightdeck/` until `recipe add` makes
/// one. Every other event under the root is dropped by a string prefix check, which costs
/// far less than the stat-polling alternative.
@MainActor
final class RouteShimWatcher {
    /// `nonisolated(unsafe)` so `deinit`, which is not main-actor isolated, can tear the
    /// stream down; FSEvents' stop/invalidate/release are safe from any thread.
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    /// Owned by the stream through the context's retain/release, so a callback already queued
    /// on main when `stop()` runs finds a live sink with a nil watcher, never a freed pointer.
    private final class Sink {
        weak var watcher: RouteShimWatcher?
    }

    private let projectRoot: URL
    private let onChange: () -> Void

    /// Nil when FSEvents refuses the stream, in which case shims are only rebuilt at launch.
    init?(projectRoot: URL, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        // FSEvents reports real paths (`/private/var/…` for `/var/…`), so the prefix check
        // must compare against the real root or it never matches. `realpath(3)`, not
        // `resolvingSymlinksInPath`: that one deliberately strips `/private` again, and the
        // first version of this watcher never fired for a project under the temp directory.
        self.projectRoot = realpath(projectRoot.path, nil).map { pointer in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        } ?? projectRoot
        self.onChange = onChange
        let sink = Sink()
        sink.watcher = self
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            guard let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { sink.watcher?.handle(changed.prefix(count), flags: flags) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [self.projectRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
    }

    /// Idempotent. Without it a watcher dropped with its project would keep a stream, and a
    /// main-queue callback, alive for the life of the app.
    nonisolated func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: ArraySlice<String>, flags: [FSEventStreamEventFlags]) {
        if paths.contains(where: { Self.isConfigChange($0, projectRoot: projectRoot) })
            || flags.contains(where: Self.mustRescan) {
            onChange()
        }
    }

    /// Events FSEvents could not deliver individually (MustScanSubDirs, set when it or the
    /// kernel dropped events under load), or the root itself being moved or deleted
    /// (RootChanged, which `WatchRoot` turns on). Either way the change to `delegate.toml` may
    /// be in what was lost, and a rebuild is cheap; without this a dropped event left a tab's
    /// shims stale until the next edit.
    nonisolated static func mustRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
    }

    /// `.flightdeck` itself (created or removed) or anything inside it — but not a nested
    /// project's `.flightdeck`, which configures that project, not this one.
    nonisolated static func isConfigChange(_ path: String, projectRoot: URL) -> Bool {
        let dir = projectRoot.appendingPathComponent(".flightdeck").path
        return path == dir || path.hasPrefix(dir + "/")
    }
}
