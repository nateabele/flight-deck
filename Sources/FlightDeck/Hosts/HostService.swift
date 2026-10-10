import Combine
import FleetKit
import Foundation
import HostKit
import Network
import OSLog
import Security

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

/// Why `HostService.enroll` did not add a host.
enum HostEnrollError: Error, Equatable {
    /// A paired host already has this name. Enrollment never renames ("gpu-2"): the name is
    /// the one the repo's `[infra.<name>]` and `run --on` use, so a rename would strand them.
    case nameInUse(String)
}

/// Owns the host registry and one `HostLink` per paired host, and pairs new ones.
@MainActor
final class HostService: ObservableObject {
    @Published private(set) var statuses: [UUID: HostLinkState] = [:]
    let registry: HostRegistry

    /// Every hostd's pairing listener port, Linux and Mac (`DarwinHostServer.pairingPort`), so
    /// an address typed without a port reaches either. A Mac host that found 47411 taken falls
    /// back to an ephemeral port and shows it on its pairing sheet, for `address:port`.
    nonisolated static let pairingPort: UInt16 = 47411

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

    /// Opens a link to every paired host. Returns at once: each host's key is read on its own
    /// GCD thread, because a read can block on `securityd` and this runs at app launch. With
    /// no hosts it does nothing at all — no read, no browse, no Keychain.
    ///
    /// **One read per host, each opening its own link the moment it returns.** Reading every
    /// key in one task and opening links only after the last read meant one unanswered
    /// Keychain prompt held every host offline: on 2026-10-10 a re-signed release prompted for
    /// m3's key at 12:05 and neither m3 nor jeeves was dialled again until it was answered.
    func start() {
        guard !started else { return }
        started = true
        let records = registry.hosts
        guard !records.isEmpty else { return }
        for record in records {
            statuses[record.slot] = .offline(lastSeen: record.lastSeenAt)
            readKey(record)
        }
    }

    // MARK: - Keys

    /// How long a read may run before the host shows why it is not dialling. A read that
    /// needs no prompt answers in milliseconds; one that runs this long is waiting on the user.
    nonisolated static let keyReadPatience: TimeInterval = 3
    /// Between failed reads; the last value repeats, so a denied prompt is asked again every
    /// five minutes rather than either never (the link latched off) or in a tight loop.
    nonisolated static let keyRetryBackoff: [TimeInterval] = [5, 15, 30, 60, 120, 300]

    /// Slots with a read running. At most one per host: a second would put a second prompt
    /// for the same item on screen.
    private var keyReads: Set<UUID> = []
    /// Failed reads in a row, per slot. Readable so a test can tell one retry from the next
    /// once the delay stops growing and the status text stops changing.
    private(set) var keyAttempts: [UUID: Int] = [:]
    private var keyTimers: [UUID: HostLinkCancellable] = [:]

    private func readKey(_ record: HostRecord) {
        let slot = record.slot
        // `record` only names the slot; `keyRead` looks the record up again, since a read can
        // outlive several updates to it.
        guard !keyReads.contains(slot), links[slot] == nil else { return }
        keyReads.insert(slot)
        keyTimers[slot]?.cancel()
        keyTimers[slot] = clock.schedule(after: Self.keyReadPatience) { [weak self] in
            guard let self, self.keyReads.contains(slot), self.isPaired(slot) else { return }
            self.statuses[slot] = .keyUnavailable(
                "waiting for Keychain access: approve Flight Deck's Keychain prompt")
        }
        let secrets = registry.secrets
        // GCD, not `Task.detached`: a read can block for hours on a prompt, and a blocked
        // thread in the cooperative pool is one fewer for every other task in the app.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = secrets.read(slot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.keyRead(slot, result) }
            }
        }
    }

    private func keyRead(_ slot: UUID, _ result: HostSecretRead) {
        keyReads.remove(slot)
        keyTimers.removeValue(forKey: slot)?.cancel()
        // Forgotten while the read ran.
        guard let record = registry.hosts.first(where: { $0.slot == slot }) else { return }
        switch result {
        case .found(let secret):
            keyAttempts[slot] = nil
            statuses[slot] = .offline(lastSeen: record.lastSeenAt)
            open(record, key: FleetDeviceKey(slot: slot, secret: secret))
        case .missing:
            // Kept, not dropped: the user should see the host and re-pair it, not wonder where
            // it went. Not retried: no amount of waiting puts a key back.
            Self.logger.error("\(record.name, privacy: .public): no key in the Keychain")
            statuses[slot] = .refused("Pair \(record.name) again: its key is missing")
        case .failed(let status):
            let attempt = keyAttempts[slot, default: 0]
            keyAttempts[slot] = attempt + 1
            let delay = Self.keyRetryBackoff[min(attempt, Self.keyRetryBackoff.count - 1)]
            Self.logger.error("\(record.name, privacy: .public): Keychain read failed, OSStatus \(status, privacy: .public); retrying in \(Int(delay), privacy: .public)s")
            statuses[slot] = .keyUnavailable("\(Self.keyFailureText(status)); retrying in \(Int(delay))s")
            keyTimers[slot] = clock.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.keyTimers[slot] = nil
                guard let current = self.registry.hosts.first(where: { $0.slot == slot }) else { return }
                self.readKey(current)
            }
        }
    }

    /// What the user can do about a failed read, in `host ls` and Settings.
    nonisolated static func keyFailureText(_ status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            return "Keychain access denied"
        case errSecInteractionNotAllowed:
            return "Keychain is locked"
        default:
            return "Keychain read failed (OSStatus \(status))"
        }
    }

    private func isPaired(_ slot: UUID) -> Bool {
        registry.hosts.contains { $0.slot == slot }
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

    /// Pairing by address, for a host Bonjour cannot reach (a Linux box without Avahi, or
    /// either kind of host across a tailnet). `address` is `host` or `host:port`; the port defaults to 47411.
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
    nonisolated static func pairingEndpoint(_ address: String) -> NWEndpoint? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPort = text.hasPrefix("[") ? text.contains("]:") : text.filter { $0 == ":" }.count == 1
        return HostLink.endpoint(from: hasPort ? text : "\(text):\(pairingPort)")
    }

    /// Ends any pairing in flight; its `pair` call throws `.cancelled`.
    func cancelPairing() {
        settlePairing(.failure(HostPairingError.cancelled))
    }

    /// Adds a host whose key this Mac minted itself (a cloud machine enrolled through its
    /// user-data), so there is no pairing exchange. `endpoints` may be empty while the machine
    /// has no address yet; `setEndpoints` supplies it once it does.
    @discardableResult
    func enroll(key: FleetDeviceKey, name: String, endpoints: [String]) throws -> HostRecord {
        if case .success = registry.resolve(name: name) { throw HostEnrollError.nameInUse(name) }
        return try adopt((key, "fd-\(name)", name, endpoints))
    }

    /// Replaces a host's addresses and redials: a link only reads its endpoints when it races,
    /// so one started with none would otherwise keep browsing Bonjour for a cloud machine that
    /// is never on this network.
    func setEndpoints(slot: UUID, _ endpoints: [String]) {
        guard var record = registry.hosts.first(where: { $0.slot == slot }) else { return }
        record.endpoints = Array(endpoints.prefix(HostRecord.maxEndpoints))
        save(record)
        // The open link's key, never `registry.key(for:)`: that is a Keychain read on the main
        // thread, and with a prompt up it would hang the UI as long as the prompt stayed
        // unanswered. No link yet means its key read is still running, and `keyRead` looks the
        // record up again when it returns, so the new endpoints are used then.
        guard let link = links.removeValue(forKey: slot) else { return }
        let key = link.key
        link.onStateChange = nil
        link.onEndpointsChanged = nil
        link.stop()
        open(record, key: key)
    }

    /// Works while the host is offline. The host keeps our slot until someone revokes it there.
    func forget(slot: UUID) {
        keyTimers.removeValue(forKey: slot)?.cancel()
        keyAttempts[slot] = nil
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

    /// The open link to a paired host, for delegation's `LiveHostDirectory`; nil before
    /// `start()` has read its key, or once it is forgotten.
    func link(slot: UUID) -> HostLink? { links[slot] }

    private func open(_ record: HostRecord, key: FleetDeviceKey) {
        // Forgotten while its key was being read, or already open.
        guard links[record.slot] == nil, isPaired(record.slot) else { return }
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
        case .connecting, .offline, .refused, .keyUnavailable:
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
