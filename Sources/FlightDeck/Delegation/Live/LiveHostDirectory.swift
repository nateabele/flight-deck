import Combine
import Foundation
import HostKit

/// `DelegationHostDirectory` over `HostService`: one `LiveHostLink` per paired host, kept for
/// as long as the host stays paired so its run feeds survive the link dropping and coming back.
@MainActor
final class LiveHostDirectory: DelegationHostDirectory {
    private let hostService: HostService
    private let mirrors: URL
    private let now: () -> Date
    private var links: [UUID: (host: HostLink, live: LiveHostLink)] = [:]
    private var online: [UUID: Bool] = [:]
    private var watch: AnyCancellable?

    /// `mirrors` is where each run's output copy lives (`RunMirror`):
    /// `Application Support/Flight Deck/delegation/`.
    init(hostService: HostService, mirrors: URL, now: @escaping () -> Date = Date.init) {
        self.hostService = hostService
        self.mirrors = mirrors
        self.now = now
        // `HostService` owns each link's single `onStateChange`; its published statuses are
        // the same transitions, one per link change.
        watch = hostService.$statuses.sink { [weak self] statuses in self?.statusesChanged(statuses) }
    }

    var hostNames: [String] { hostService.registry.hosts.map(\.name) }

    /// The §5 lines when it cannot be used: `HostProjection`'s, so `flightdeck run --on mini`
    /// and `flightdeck host info mini` word an offline or unknown host the same way.
    func link(named name: String) throws -> any HostLinking {
        let record: HostRecord
        do { record = try hostService.registry.resolve(name: name).get() } catch {
            throw refusal(error, name: name)
        }
        guard let host = hostService.link(slot: record.slot), host.isOnline else {
            throw refusal(HostLinkError.offline, name: name)
        }
        if let cached = links[record.slot], cached.host === host { return cached.live }
        let live = LiveHostLink(name: record.name, transport: host, mirrors: mirrors,
                                mirrorPrefix: record.slot.uuidString)
        host.onEvent = { [weak live] runID, event in live?.received(runID: runID, event) }
        links[record.slot] = (host, live)
        online[record.slot] = true
        return live
    }

    /// Deletes the output copies of `host`'s runs `runIDs` (host run ids), for the registry when
    /// it forgets runs. Works with the host offline: the copies are this Mac's.
    func prune(host: String, runIDs: [String]) {
        guard let record = try? hostService.registry.resolve(name: host).get() else { return }
        if let live = links[record.slot]?.live { return live.prune(runIDs: runIDs) }
        for runID in runIDs {
            RunMirror(url: LiveHostLink.mirrorURL(in: mirrors, prefix: record.slot.uuidString, runID: runID)).delete()
        }
    }

    private func refusal(_ error: Error, name: String) -> DelegationError {
        let (code, message) = HostProjection.refusal(for: error, name: name, registry: hostService.registry,
                                                     state: { [hostService] in hostService.statuses[$0] }, now: now())
        return DelegationError(code: code, message: message)
    }

    private func statusesChanged(_ statuses: [UUID: HostLinkState]) {
        for (slot, entry) in links {
            switch statuses[slot] {
            case nil:
                // Forgotten: no reconnect is coming.
                entry.live.close(DelegationError(code: "host_forgotten",
                                                 message: "\(entry.live.name) was removed from Settings › Hosts — the run carries on there, out of reach"))
                entry.host.onEvent = nil
                links[slot] = nil
                online[slot] = nil
            case .refused(let reason)?:
                entry.live.close(DelegationError(code: "host_refused", message: "\(entry.live.name): \(reason)"))
                entry.host.onEvent = nil
                links[slot] = nil
                online[slot] = nil
            case let state?:
                let isOnline: Bool
                if case .online = state { isOnline = true } else { isOnline = false }
                guard online[slot] != isOnline else { continue }
                online[slot] = isOnline
                // The sink runs as the value is about to be published; the link has already
                // switched (`onStateChange` fires from its `didSet`), so a re-attach sent now
                // goes out on the new connection.
                entry.live.connectionChanged(online: isOnline)
            }
        }
    }
}
