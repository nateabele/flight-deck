import Foundation

/// What `SessionStore` tells delegation about its tabs. A protocol so the store's tests can
/// see the calls without a real shim directory, and so the store never learns what a route
/// shim or a delegated service is.
@MainActor
protocol DelegationSessionHooks: AnyObject {
    /// `environment` as `session`'s shell should be launched with: route shims first on `PATH`
    /// (spec §8). Called for every surface a tab gets, a fresh launch or a reattach to a live
    /// daemon alike, so a tab adopted from the previous app run is watched again too.
    func launchEnvironment(_ environment: [String: String], session: UUID, projectRoot: URL) -> [String: String]
    /// The tab closed.
    func sessionClosed(_ session: UUID)
}

/// Brings delegation up beside the app, outside `DelegationService`'s own file: the route
/// shims every tab is launched with, and the service the control socket answers through.
///
/// Built in `FlightDeckApp.init`, before the store, because the store launches its restored
/// tabs inside its own initializer: hooks handed over any later would leave every restored
/// tab without its shim directory on `PATH` for the life of its shell. Never built under a
/// UITest reset, so a GUI run neither writes shims nor reaches a host.
@MainActor
final class DelegationBootstrap: DelegationSessionHooks {
    /// Names the session's own shim directory, so the CLI's local fall-through can skip it on
    /// `PATH` and never exec the shim it was called from.
    static let shimDirVariable = "FLIGHTDECK_SHIM_DIR"

    /// Nil when the bundle carries no shim script, in which case routing is simply absent.
    private let shims: RouteShims?
    private let cli: URL?
    /// Live tabs by project, so one watcher rebuilds every tab of the project it fired for.
    private var sessions: [URL: Set<UUID>] = [:]
    private var watchers: [URL: RouteShimWatcher] = [:]

    init(shims: RouteShims?, cli: URL? = RouteShims.bundledCLI()) {
        self.shims = shims
        self.cli = cli
    }

    convenience init(stateDirectory: URL, bundle: Bundle = .main) {
        self.init(
            shims: RouteShims.bundledScript(bundle).map {
                RouteShims(root: RouteShims.defaultRoot(stateDirectory: stateDirectory), script: $0)
            },
            cli: RouteShims.bundledCLI(bundle))
    }

    // MARK: Delegation

    /// Builds the real service and hands it to the control socket.
    ///
    /// `sessionTitle` names the tab in the host's screen-queue message ("waiting on the screen
    /// for <tab>"); without it every run there reads "terminal".
    ///
    /// Keeping runs watched is the service's own job, not this one's: its `init` resumes the
    /// registry's live runs, and the factory points `LiveHostDirectory.onHostOnline` at
    /// `resumeWatching`. That hook fires on the main-actor turn *after* the status is
    /// published; a `$statuses` sink here would fire in `willSet`, before the link reads as
    /// online, so `resumeWatching` would skip the very host that just came up.
    func connect(fleet: FleetService, hosts: HostService, sessionTitle: @escaping (UUID) -> String?) {
        fleet.delegation = DelegationServiceFactory.live(hostService: hosts, sessionTitle: sessionTitle)
    }

    // MARK: DelegationSessionHooks

    func launchEnvironment(_ environment: [String: String], session: UUID, projectRoot: URL) -> [String: String] {
        guard let shims else { return environment }
        let project = projectRoot.standardizedFileURL
        // Built before the shell starts, so a routed command typed the moment the prompt
        // appears is already intercepted. A config that does not parse leaves the directory
        // as it was (`rebuild`'s rule), and a `PATH` entry for a directory not made yet
        // finds nothing, so the tab runs everything locally until the file parses.
        shims.rebuild(session: session, projectRoot: project)
        sessions[project, default: []].insert(session)
        watch(project)
        var result = RouteShims.environment(environment, prepending: shims.directory(for: session), cli: cli)
        result[Self.shimDirVariable] = shims.directory(for: session).path
        return result
    }

    /// Removes the tab's shim directory and, with its project's last tab, the watcher.
    ///
    /// Delegated services are not downed here: `FleetService` already does that on this same
    /// close, from the store's `sessionRemoved` event, once `connect` has set its `delegation`.
    /// Calling `DelegationService.sessionClosed` here as well would send every service's
    /// `service.down` twice.
    func sessionClosed(_ session: UUID) {
        shims?.remove(session: session)
        for (project, members) in sessions where members.contains(session) {
            sessions[project]?.remove(session)
            if sessions[project]?.isEmpty == true {
                sessions[project] = nil
                watchers.removeValue(forKey: project)?.stop()
            }
        }
    }

    /// The shim directories currently tracked for `projectRoot`, for tests.
    func trackedSessions(in projectRoot: URL) -> Set<UUID> { sessions[projectRoot.standardizedFileURL] ?? [] }

    private func watch(_ project: URL) {
        guard watchers[project] == nil, let shims else { return }
        watchers[project] = RouteShimWatcher(projectRoot: project) { [weak self] in
            guard let self else { return }
            for session in self.sessions[project] ?? [] {
                shims.rebuild(session: session, projectRoot: project)
            }
        }
    }
}
