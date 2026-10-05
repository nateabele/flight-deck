import Foundation
import HostKit

/// Builds the real `DelegationService`: every seam on its live adapter.
@MainActor
enum DelegationServiceFactory {
    /// `stateDirectory` defaults to where `hosts.json` and `sessions.json` live, through the
    /// same resolution, so a Debug build keeps its runs and output copies in
    /// "Flight Deck (Debug)". `sessionTitle` names a tab for the host's screen-queue message;
    /// without it every run is labelled "terminal".
    ///
    /// Each run's output copy (`RunMirror`, ruling 21) is
    /// `<stateDirectory>/delegation/<host slot>-<host run id>.out`: host run ids are `r<N>` on
    /// every host, so the slot keeps two hosts' `r3` apart. `LiveHostDirectory.prune(host:runIDs:)`
    /// takes host run ids (`DelegatedRun.hostRunID`) for that reason.
    ///
    /// Not wired here: acking a fetched result on the host. The wire has no op for it
    /// (`DelegationRequest` lacks one); the host acks after sending (W1), until the final
    /// integration adds a controller-driven `run.ack`.
    static func live(hostService: HostService, stateDirectory: URL? = nil,
                     sessionTitle: @escaping (UUID) -> String? = { _ in nil },
                     forwarder: PortForwarder = PortForwarder()) -> DelegationService {
        let state = stateDirectory ?? FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory()
        let directory = state.appendingPathComponent("delegation", isDirectory: true)
        let registry = hostService.registry
        let hosts = LiveHostDirectory(hostService: hostService, mirrors: directory)
        let dependencies = DelegationService.Dependencies(
            hosts: hosts,
            preflight: LivePreflight(forwarder: forwarder),
            snapshots: LiveSnapshotter(),
            bundles: LiveBundleMaker(),
            results: LiveResultApplier(),
            config: LiveConfigLoader(platforms: {
                Dictionary(registry.hosts.compactMap { host in host.platform.map { (host.name, $0) } },
                           uniquingKeysWith: { first, _ in first })
            }),
            worktrees: LiveWorktreeLocator(),
            sessionTitle: sessionTitle,
            directory: directory)
        let service = DelegationService(registry: RunRegistry(file: state.appendingPathComponent("delegation.json")),
                                        dependencies: dependencies)
        // Runs whose host was offline at launch are skipped by the service's own first pass.
        hosts.onHostOnline = { [weak service] in service?.resumeWatching() }
        return service
    }
}
