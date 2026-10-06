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
    /// Every slot's last known "online", links handed out or not, for `onHostOnline`.
    private var wasOnline: [UUID: Bool] = [:]
    /// A host's link came up: the factory points this at `DelegationService.resumeWatching`,
    /// so runs whose host was offline at launch (or dropped since) are watched again without
    /// waiting for someone to ask about them.
    var onHostOnline: (() -> Void)?
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
    ///
    /// **An offline host still gets a link.** Its runs' output is on this Mac (`RunMirror`),
    /// so `logs` on a finished run answers from that copy; every request and channel refuses
    /// with the offline line, and a run still going waits for the link to come back. Only a
    /// host with no link at all (its key not read yet, or missing) is refused here.
    func link(named name: String) throws -> any HostLinking {
        let record: HostRecord
        do { record = try hostService.registry.resolve(name: name).get() } catch {
            throw refusal(error, name: name)
        }
        guard let host = hostService.link(slot: record.slot) else {
            throw refusal(HostLinkError.offline, name: name)
        }
        if let cached = links[record.slot], cached.host === host { return cached.live }
        let live = LiveHostLink(name: record.name, transport: host, mirrors: mirrors,
                                mirrorPrefix: record.slot.uuidString)
        live.unavailable = { [weak self] in
            self?.refusal(HostLinkError.offline, name: name)
                ?? DelegationError(code: "host_offline", message: "\(name) is offline")
        }
        host.onEvent = { [weak live] runID, event in live?.received(runID: runID, event) }
        links[record.slot] = (host, live)
        online[record.slot] = host.isOnline
        return live
    }

    func forget(_ runs: [DelegatedRun]) {
        for (host, runs) in Dictionary(grouping: runs, by: \.host) {
            let pairs = runs.map { (hostRunID: $0.hostRunID, localID: $0.id) }
            // The live link ends any reader of these copies; a host no longer paired, or never
            // linked this launch, has none, and its copies are plain files.
            if let slot = try? hostService.registry.resolve(name: host).get().slot, let live = links[slot]?.live {
                live.prune(pairs)
            } else {
                for run in pairs { RunMirror(url: LiveHostLink.mirrorURL(in: mirrors, localID: run.localID)).delete() }
            }
        }
    }

    private func refusal(_ error: Error, name: String) -> DelegationError {
        let (code, message) = HostProjection.refusal(for: error, name: name, registry: hostService.registry,
                                                     state: { [hostService] in hostService.statuses[$0] }, now: now())
        return DelegationError(code: code, message: message)
    }

    private func statusesChanged(_ statuses: [UUID: HostLinkState]) {
        var cameOnline = false
        for (slot, state) in statuses {
            let isOnline: Bool
            if case .online = state { isOnline = true } else { isOnline = false }
            if isOnline, wasOnline[slot] != true { cameOnline = true }
            wasOnline[slot] = isOnline
        }
        wasOnline = wasOnline.filter { statuses[$0.key] != nil }
        if cameOnline {
            // After this publish lands: the sink runs before `statuses` is assigned, and the
            // watchers it starts read the link's state through the directory.
            Task { @MainActor [weak self] in self?.onHostOnline?() }
        }
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
