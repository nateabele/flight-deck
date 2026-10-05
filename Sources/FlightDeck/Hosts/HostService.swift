import Combine
import FleetKit
import Foundation
import HostKit
import Network
import OSLog

/// Why `HostService.pair` did not produce a host.
enum HostPairingError: Error, Equatable {
    /// Nothing on this network is offering to pair. Different advice from a failure: "show
    /// the code on the host", not "wrong code".
    case noHostsFound
    case failed(PairingInitiator.Failure)
    /// Not a `host` or `host:port` this controller can dial.
    case badAddress
    /// Another `pair` call, or `cancelPairing()`, replaced this one.
    case cancelled
}

/// Owns the host registry and one `HostLink` per paired host, and pairs new ones.
@MainActor
final class HostService: ObservableObject {
    @Published private(set) var statuses: [UUID: HostLinkState] = [:]
    let registry: HostRegistry

    /// The Linux hostd's pairing listener port. A Mac host's listener is ephemeral and is
    /// found through `_fd-host-pair._tcp`, so typing an address only reaches Linux hosts.
    static let pairingPort: UInt16 = 47411

    private let controllerName: String
    private let dial: HostLinkDialing
    private let clock: HostLinkClock
    private var links: [UUID: HostLink] = [:]
    private var started = false

    private typealias Paired = (key: FleetDeviceKey, serviceName: String, name: String, endpoints: [String])
    private var pairing: CheckedContinuation<Paired, Error>?
    /// The runner or initiator driving `pairing`, kept alive for as long as it runs.
    private var pairingDriver: AnyObject?

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "hosts")

    init(registry: HostRegistry, controllerName: String,
         dial: HostLinkDialing = NetworkHostDialer(), clock: HostLinkClock = SystemHostLinkClock()) {
        self.registry = registry
        self.controllerName = controllerName
        self.dial = dial
        self.clock = clock
    }

    /// Opens a link to every paired host. Returns at once: the Keychain is read on a
    /// background task, because a read can block on `securityd` and this runs at app
    /// launch. With no hosts it does nothing at all — no task, no browse, no Keychain.
    func start() {
        guard !started else { return }
        started = true
        let records = registry.hosts
        guard !records.isEmpty else { return }
        for record in records { statuses[record.slot] = .offline(lastSeen: record.lastSeenAt) }
        let secrets = registry.secrets
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                records.map { ($0, secrets.secret(for: $0.slot)) }
            }.value
            guard let self else { return }
            for (record, secret) in found {
                guard let secret else {
                    // Kept, not dropped: the user should see the host and re-pair it, not
                    // wonder where it went.
                    Self.logger.error("\(record.name, privacy: .public): no key in the Keychain")
                    self.statuses[record.slot] = .refused("Pair \(record.name) again: its key is missing")
                    continue
                }
                self.open(record, key: FleetDeviceKey(slot: record.slot, secret: secret))
            }
        }
    }

    func info(name: String) async throws -> (HostRecord, HostInfo) {
        let record = try registry.resolve(name: name).get()
        guard let link = links[record.slot] else { throw HostLinkError.offline }
        switch try await link.request(.hostInfo) {
        case .delegation:
            // A host answering `host.info` with a delegation reply is a host bug; refused
            // rather than trusted, under the code a malformed answer would get.
            throw HostLinkError.remote(code: "unexpected_reply", message: "\(name) answered host.info with something else")
        case .hostInfo(let info):
            var current = registry.hosts.first { $0.slot == record.slot } ?? record
            if current.platform != info.platform {
                current.platform = info.platform
                save(current)
            }
            return (current, info)
        }
    }

    /// Typed-code pairing over Bonjour: `candidate` when the sheet already found the host,
    /// otherwise a fresh browse of `_fd-host-pair._tcp`.
    func pair(code: PairingCode, candidate: PairingBrowser.DiscoveredMac?) async throws -> HostRecord {
        let paired = try await awaitPairing { settle in
            let runner = PairingRunner(profile: .host)
            runner.onPaired = { key, serviceName, hostName in
                // No address yet: the link finds the host by `serviceName`, then learns the
                // address that answered and the host's own list from helloAck.
                settle(.success((key, serviceName, hostName, [])))
            }
            runner.onProgress = { progress in
                switch progress {
                case .noMacsFound: settle(.failure(HostPairingError.noHostsFound))
                case .failed(let failure): settle(.failure(HostPairingError.failed(failure)))
                case .searching, .trying, .paired: break
                }
            }
            if let candidate { runner.start(code: code, candidates: [candidate]) } else { runner.start(code: code) }
            return runner
        }
        return try adopt(paired)
    }

    /// Pairing by address, for a host Bonjour cannot reach (a Linux box without Avahi, or one
    /// across a tailnet). `address` is `host` or `host:port`; the port defaults to 47411.
    func pair(code: PairingCode, address: String) async throws -> HostRecord {
        guard let endpoint = Self.pairingEndpoint(address),
              case .hostPort(let host, _) = endpoint
        else { throw HostPairingError.badAddress }
        // Bracketed so a stored IPv6 address still splits at its last colon.
        let hostText: String
        if case .ipv6 = host { hostText = "[\(host)]" } else { hostText = "\(host)" }
        let paired = try await awaitPairing { settle in
            let initiator = PairingInitiator(profile: .host)
            initiator.onPaired = { key, hostName in
                // The pairing port is not the host port: the link dials the fixed 47410.
                settle(.success((key, hostName, hostName, ["\(hostText):\(HostLink.hostPort)"])))
            }
            initiator.onFailure = { settle(.failure(HostPairingError.failed($0))) }
            initiator.start(code: code, endpoint: endpoint)
            return initiator
        }
        return try adopt(paired)
    }

    /// `host`, `host:port`, `[v6]` or `[v6]:port`. A bare IPv6 literal has several colons and
    /// no port, so only one colon, or `]:`, means a port was given.
    static func pairingEndpoint(_ address: String) -> NWEndpoint? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPort = text.hasPrefix("[") ? text.contains("]:") : text.filter { $0 == ":" }.count == 1
        return HostLink.endpoint(from: hasPort ? text : "\(text):\(pairingPort)")
    }

    /// Ends any pairing in flight; its `pair` call throws `.cancelled`.
    func cancelPairing() {
        settlePairing(.failure(HostPairingError.cancelled))
    }

    /// Works while the host is offline. The host keeps our slot until someone revokes it there.
    func forget(slot: UUID) {
        if let link = links.removeValue(forKey: slot) {
            // Detached first, or `stop()`'s own `.offline` report would put the status back.
            link.onStateChange = nil
            link.onEndpointsChanged = nil
            link.stop()
        }
        statuses.removeValue(forKey: slot)
        registry.remove(slot: slot)
    }

    // MARK: - Links

    private func open(_ record: HostRecord, key: FleetDeviceKey) {
        // Forgotten while its key was being read, or already open.
        guard links[record.slot] == nil, registry.hosts.contains(where: { $0.slot == record.slot })
        else { return }
        let link = HostLink(record: record, key: key, controllerName: controllerName,
                            dial: dial, clock: clock)
        let slot = record.slot
        link.onStateChange = { [weak self] state in self?.linkChanged(slot, state) }
        link.onEndpointsChanged = { [weak self] endpoints in self?.learned(slot, endpoints) }
        links[slot] = link
        statuses[slot] = link.state
        link.start()
    }

    private func linkChanged(_ slot: UUID, _ state: HostLinkState) {
        statuses[slot] = state
        guard var record = registry.hosts.first(where: { $0.slot == slot }) else { return }
        switch state {
        case .online:
            record.lastSeenAt = clock.now
            save(record)
            // The platform comes only from `host.info`; ask once so `host ls` can show it.
            if record.platform == nil {
                Task { [weak self] in _ = try? await self?.info(name: record.name) }
            }
        case .offline(let lastSeen?) where lastSeen != record.lastSeenAt:
            record.lastSeenAt = lastSeen
            save(record)
        case .connecting, .offline, .refused:
            break
        }
    }

    /// The link's merge (`HostLink.mergedEndpoints`), persisted so the next launch dials the
    /// host's tailnet address even if this run never needed it.
    private func learned(_ slot: UUID, _ endpoints: [String]) {
        guard var record = registry.hosts.first(where: { $0.slot == slot }) else { return }
        record.endpoints = endpoints
        save(record)
    }

    private func save(_ record: HostRecord) {
        // The registry is not observable, so the Hosts tab would otherwise show a host's
        // platform and last-seen time only after some later status change happened to redraw it.
        objectWillChange.send()
        registry.update(record)
        links[record.slot]?.record = record
    }

    // MARK: - Pairing

    private func adopt(_ paired: Paired) throws -> HostRecord {
        let record = try registry.add(key: paired.key, name: paired.name,
                                      serviceName: paired.serviceName, endpoints: paired.endpoints)
        open(record, key: paired.key)
        return record
    }

    /// Bridges a callback pairing driver to `async`. One pairing at a time: a second call
    /// cancels the first, whose caller gets `.cancelled` instead of a continuation that never
    /// resumes.
    private func awaitPairing(
        _ begin: (_ settle: @escaping (Result<Paired, Error>) -> Void) -> AnyObject
    ) async throws -> Paired {
        settlePairing(.failure(HostPairingError.cancelled))
        return try await withCheckedThrowingContinuation { continuation in
            pairing = continuation
            pairingDriver = begin { [weak self] result in self?.settlePairing(result) }
        }
    }

    /// Exactly once per pairing: the runner reports `.paired` after `onPaired`, and a cancel
    /// can race a verdict.
    private func settlePairing(_ result: Result<Paired, Error>) {
        guard let continuation = pairing else { return }
        pairing = nil
        let driver = pairingDriver
        pairingDriver = nil
        (driver as? PairingRunner)?.cancel()
        (driver as? PairingInitiator)?.cancel()
        continuation.resume(with: result)
    }
}
