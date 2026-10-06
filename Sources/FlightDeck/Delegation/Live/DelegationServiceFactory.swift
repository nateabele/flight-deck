import AppKit
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
    /// Each run's output copy (`RunMirror`; Ruling 21: the app keeps every run's output and
    /// replays from it) is `<stateDirectory>/delegation/<local run id>.out`, beside the run's
    /// result bundle: local ids are never reused, so neither is a copy's name.
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
        // The registry's writes are coalesced (`RunRegistry.save`); one still waiting out its
        // delay at quit would be lost with the process.
        let runs = service.registry
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { runs.flush() }
        }
        return service
    }
}
