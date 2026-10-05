import Foundation
import HostKit

/// Builds the real `DelegationService`: every seam on its live adapter.
@MainActor
enum DelegationServiceFactory {
    /// `stateDirectory` defaults to where `hosts.json` and `sessions.json` live, through the
    /// same resolution, so a Debug build keeps its runs and output copies in
    /// "Flight Deck (Debug)". `sessionTitle` names a tab for the host's screen-queue message;
    /// without it every run is labelled "terminal".
    static func live(hostService: HostService, stateDirectory: URL? = nil,
                     sessionTitle: @escaping (UUID) -> String? = { _ in nil },
                     forwarder: PortForwarder = PortForwarder()) -> DelegationService {
        let state = stateDirectory ?? FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory()
        let directory = state.appendingPathComponent("delegation", isDirectory: true)
        let registry = hostService.registry
        let dependencies = DelegationService.Dependencies(
            hosts: LiveHostDirectory(hostService: hostService, mirrors: directory),
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
        return DelegationService(registry: RunRegistry(file: state.appendingPathComponent("delegation.json")),
                                 dependencies: dependencies)
    }
}
