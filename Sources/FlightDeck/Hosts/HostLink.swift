import FleetKit
import Foundation
import HostKit
import Network
import OSLog

enum HostLinkState: Equatable {
    /// The first race after `start()`. A retry after a drop stays `.offline` rather than
    /// flickering through this every backoff step.
    case connecting
    case online(hostName: String)
    case offline(lastSeen: Date?)
    /// The host turned us away and the link has stopped retrying; the text is for the user.
    case refused(String)
}

enum HostLinkError: Error, Equatable {
    /// Not online when asked, or the link dropped before the reply.
    case offline
    /// The host answered with an `err` frame.
    case remote(code: String, message: String)
    /// No reply within `HostLink.requestTimeout`.
    case timedOut
}

// MARK: - Seams

/// A cancellable handle: a timer, a browse, a path watch.
@MainActor
protocol HostLinkCancellable: AnyObject {
    func cancel()
}

/// Every delay `HostLink` waits on — backoff, race deadline, ping cadence, request timeout —
/// goes through this, so a test can step a 30 s backoff or a 45 s liveness window without
/// waiting it out.
@MainActor
protocol HostLinkClock: AnyObject {
    var now: Date { get }
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> HostLinkCancellable
}

@MainActor
final class SystemHostLinkClock: HostLinkClock {
    /// Nonisolated so it can be a default argument, which Swift evaluates outside the actor.
    nonisolated init() {}

    var now: Date { Date() }

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> HostLinkCancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemHandle(item: item)
    }

    private final class WorkItemHandle: HostLinkCancellable {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

/// One WebSocket to one candidate address. Callbacks arrive on the main actor, and none of
/// them fires after `cancel()`, so the link never has to ask whether a callback is stale.
@MainActor
protocol HostLinkConnection: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onText: ((String) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    /// The `host:port` actually reached, once ready — what a Bonjour win teaches the link.
    var remoteAddress: String? { get }
    func start()
    func send(_ text: String)
    func ping(onPong: @escaping () -> Void)
    func cancel()
}

/// What `HostLink` needs from the network, behind a protocol so liveness, refusal and
/// learning can be driven by a test without a host that misbehaves on cue.
@MainActor
protocol HostLinkDialing {
    func connection(to endpoint: NWEndpoint, key: FleetDeviceKey) -> HostLinkConnection
    /// Reports the full set of `_fd-host._tcp` services named `serviceName` on every change.
    func browse(serviceName: String, onChange: @escaping ([NWEndpoint]) -> Void) -> HostLinkCancellable
    /// Fires on each network path change after the first report, which is only the baseline.
    func watchPath(onChange: @escaping () -> Void) -> HostLinkCancellable
}

// MARK: - The link

/// One live, authenticated connection to one paired host.
///
/// **Dialing races every candidate at once** — each stored address plus whatever Bonjour
/// finds under the host's service name — and the first to answer `helloAck` wins, for the
/// reason `FleetConnector.race()` gives: the key identifies the host, so the first handshake
/// to complete is by definition the right one, and trying addresses in turn would make a
/// controller that changed networks wait out a TCP timeout per stale address.
///
/// **The browse outlives a failed race.** It runs whenever the link is not online, and a host
/// appearing mid-backoff starts a race at once. Without that, a stale stored address that is
/// *refused* in a millisecond would end every race before Bonjour had resolved anything, and
/// a host reachable only through Bonjour would never be reached.
@MainActor
final class HostLink {
    /// Must equal `DarwinHostServer.serviceType` (pinned by `HostLinkTests`); the Linux
    /// hostd's Avahi advertisement uses the same type.
    static let bonjourType = "_fd-host._tcp"
    /// The host listener's fixed port on both hostds.
    static let hostPort: UInt16 = 47410
    /// Between failed races; the last value repeats.
    static let backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Well short of a TCP connect timeout, as `FleetConnector.raceTimeout` is: a stale
    /// candidate that never answers must not hold the race for a minute.
    static let raceTimeout: TimeInterval = 8
    static let pingInterval: TimeInterval = 15
    /// Pings in a row that may go unanswered before the link is declared dead. A socket on an
    /// interface that stopped routing reports nothing; this is the only way to notice it.
    static let missedPongLimit = 3
    static let requestTimeout: TimeInterval = 10

    /// Settable so `HostService` can hand over a record whose endpoints it just persisted;
    /// the next race dials those.
    var record: HostRecord
    private(set) var state: HostLinkState {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((HostLinkState) -> Void)?
    /// The record's endpoints as they should now be, after a win taught the link something:
    /// the address that answered, and the host's own list from `helloAck`. Fired only when
    /// that differs from `record.endpoints`. The link does not store it itself; `HostService`
    /// persists it and assigns `record`.
    var onEndpointsChanged: (([String]) -> Void)?

    private let key: FleetDeviceKey
    private let controllerName: String
    private let dial: HostLinkDialing
    private let clock: HostLinkClock

    private var running = false
    private var racers: [String: HostLinkConnection] = [:]
    private var winner: HostLinkConnection?
    private var browser: HostLinkCancellable?
    private var bonjour: [NWEndpoint] = []
    private var pathWatch: HostLinkCancellable?
    /// Non-nil exactly while a race is running.
    private var raceTimer: HostLinkCancellable?
    private var retryTimer: HostLinkCancellable?
    private var pingTimer: HostLinkCancellable?
    private var attempt = 0
    private var missedPongs = 0
    private var lastSeen: Date?
    private var nextRequestID = 1
    /// Every entry is resolved exactly once — reply, error, timeout, or `.offline` when the
    /// link drops or stops. A continuation left here forever is a CLI call that never returns.
    private var pending: [Int: (continuation: CheckedContinuation<HostReply, Error>,
                                timer: HostLinkCancellable)] = [:]
    /// The winner's byte channels (HostLinkChannels.swift). Internal, not private, only so
    /// that file's extension can reach it; a mux lives exactly as long as one winner, since
    /// its ids and credit mean nothing on the next connection.
    var channelMux: ChannelMux?
    /// What the winner's helloAck advertised; nil while no connection is live. Delegation's
    /// preflight checks a plan's needs against it before reserving anything (§7 step 2).
    private(set) var capabilities: Set<HostCapability>?
    /// Every run `event` frame on the live connection (protocol 1.1), for delegation's run
    /// streams. One listener: `LiveHostLink` fans them out to its subscribers.
    var onEvent: ((String, RunEvent) -> Void)?

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "hosts")

    init(record: HostRecord, key: FleetDeviceKey, controllerName: String,
         dial: HostLinkDialing = NetworkHostDialer(), clock: HostLinkClock = SystemHostLinkClock()) {
        self.record = record
        self.key = key
        self.controllerName = controllerName
        self.dial = dial
        self.clock = clock
        lastSeen = record.lastSeenAt
        state = .offline(lastSeen: record.lastSeenAt)
    }

    func start() {
        guard !running else { return }
        running = true
        attempt = 0
        state = .connecting
        pathWatch = dial.watchPath { [weak self] in self?.pathChanged() }
        race()
    }

    func stop() {
        running = false
        teardown()
        pathWatch?.cancel()
        pathWatch = nil
        if case .refused = state { return }
        state = .offline(lastSeen: lastSeen)
    }

    /// `timeout` is longer than the default only for a request whose reply waits on bulk work
    /// on the host, which would otherwise fail `.timedOut` while the host is still working.
    ///
    /// With `progress` it is an idle timeout instead: it runs from the later of the send and
    /// the last activity `progress` reports. A `sync.push` reply follows the whole bundle, so
    /// any fixed bound either fails a big first sync mid-transfer or leaves a dead one hanging;
    /// a transfer that is still moving never times out, and one that stalls fails `timeout`
    /// after it stopped.
    func request(_ r: HostRequest, timeout: TimeInterval = HostLink.requestTimeout,
                 progress: (@MainActor () -> Date)? = nil) async throws -> HostReply {
        guard case .online = state, let winner else { throw HostLinkError.offline }
        let id = nextRequestID
        nextRequestID += 1
        let text = try HostWire.encode(HostClientFrame.request(id: id, r))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (continuation, expire(id, after: timeout, idle: timeout, progress: progress))
            winner.send(text)
        }
    }

    /// Fails request `id` after `delay`, unless `progress` reports activity within the last
    /// `idle` seconds, in which case it checks again when that activity is `idle` old.
    private func expire(_ id: Int, after delay: TimeInterval, idle: TimeInterval,
                        progress: (@MainActor () -> Date)?) -> HostLinkCancellable {
        clock.schedule(after: delay) { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            if let progress {
                let quiet = self.clock.now.timeIntervalSince(progress())
                if quiet < idle {
                    self.pending[id]?.timer = self.expire(id, after: idle - quiet, idle: idle, progress: progress)
                    return
                }
            }
            self.resolve(id, .failure(.timedOut))
        }
    }

    // MARK: Race

    private func race() {
        guard running, winner == nil else { return }
        retryTimer?.cancel()
        retryTimer = nil
        cancelRacers()
        for text in record.endpoints {
            if let endpoint = Self.endpoint(from: text) { dialCandidate(text, endpoint) }
        }
        for endpoint in bonjour { dialCandidate("bonjour:\(endpoint)", endpoint) }
        startBrowsing()
        raceTimer = clock.schedule(after: Self.raceTimeout) { [weak self] in self?.raceFailed() }
    }

    private func dialCandidate(_ description: String, _ endpoint: NWEndpoint) {
        guard running, winner == nil, racers[description] == nil else { return }
        let connection = dial.connection(to: endpoint, key: key)
        racers[description] = connection
        // Weak: the connection owns these closures, so a strong capture is a cycle.
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.sendHello(on: connection)
        }
        connection.onText = { [weak self, weak connection] text in
            guard let self, let connection else { return }
            self.received(text, from: connection)
        }
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.closed(connection, description)
        }
        connection.start()
    }

    private func sendHello(on connection: HostLinkConnection) {
        do {
            connection.send(try HostWire.encode(HostClientFrame.hello(
                protocolVersion: .current, capabilities: [.hostInfo], controllerName: controllerName)))
        } catch {
            Self.logger.error("hello encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func received(_ text: String, from connection: HostLinkConnection) {
        let frame: HostServerFrame
        do {
            frame = try HostWire.decode(HostServerFrame.self, from: text)
        } catch {
            // A newer host's frame this build cannot read costs that frame, not the link.
            Self.logger.error("\(self.record.name, privacy: .public): unreadable frame: \(String(describing: error), privacy: .public)")
            return
        }
        let isRacer = racers.values.contains { $0 === connection }
        guard connection === winner || isRacer else { return }
        if case .refused(let reason) = frame {
            return refuse(reason)
        }
        if connection === winner {
            // Any frame is proof of life, as good as a pong.
            missedPongs = 0
            lastSeen = clock.now
            switch frame {
            case .reply(let id, let reply): resolve(id, .success(reply))
            case .error(let id, let code, let message): resolve(id, .failure(.remote(code: code, message: message)))
            case .helloAck, .refused: break
            case .event(let runID, let event):
                onEvent?(runID, event)
            }
        } else if case .helloAck(_, let caps, let hostName, let advertised) = frame {
            capabilities = Set(caps)
            win(connection, hostName: hostName, advertised: advertised)
        }
    }

    private func win(_ connection: HostLinkConnection, hostName: String, advertised: [String]) {
        winner = connection
        cancelRacers()
        raceTimer?.cancel()
        raceTimer = nil
        stopBrowsing()
        attempt = 0
        missedPongs = 0
        lastSeen = clock.now
        let merged = Self.mergedEndpoints(won: connection.remoteAddress, advertised: advertised,
                                          stored: record.endpoints)
        if merged != record.endpoints { onEndpointsChanged?(merged) }
        schedulePing()
        attachChannels(to: connection)
        state = .online(hostName: hostName)
    }

    private func closed(_ connection: HostLinkConnection, _ description: String) {
        if connection === winner { return dropped() }
        guard racers[description] === connection else { return }
        racers.removeValue(forKey: description)
        // Every candidate dialled so far has failed. The browse keeps running through the
        // backoff, so a host Bonjour finds later still starts a race at once.
        if racers.isEmpty, raceTimer != nil { raceFailed() }
    }

    private func raceFailed() {
        guard running, winner == nil else { return }
        raceTimer?.cancel()
        raceTimer = nil
        cancelRacers()
        scheduleRetry()
        state = .offline(lastSeen: lastSeen)
    }

    /// The live connection is gone: closed by the host, or silent past `missedPongLimit`.
    private func dropped() {
        capabilities = nil
        winner?.cancel()
        winner = nil
        pingTimer?.cancel()
        pingTimer = nil
        failPending()
        detachChannels()
        // Scheduled before the state is reported, so a handler reading the link already sees
        // the retry it is waiting on.
        scheduleRetry()
        startBrowsing()
        state = .offline(lastSeen: lastSeen)
    }

    private func scheduleRetry() {
        guard running else { return }
        retryTimer?.cancel()
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        retryTimer = clock.schedule(after: delay) { [weak self] in
            self?.retryTimer = nil
            self?.race()
        }
    }

    /// A major-version refusal. Retrying cannot help — one side has to be updated — so the
    /// link stops until it is started again.
    private func refuse(_ reason: HostRefusal) {
        switch reason {
        case .majorVersionMismatch(let host):
            Self.logger.error("\(self.record.name, privacy: .public) refused us: host protocol \(host.major).\(host.minor), ours \(ProtocolVersion.current.major).\(ProtocolVersion.current.minor)")
        }
        running = false
        teardown()
        pathWatch?.cancel()
        pathWatch = nil
        state = .refused("Update Flight Deck on \(record.name)")
    }

    // MARK: Liveness

    private func schedulePing() {
        pingTimer = clock.schedule(after: Self.pingInterval) { [weak self] in self?.pingTick() }
    }

    private func pingTick() {
        guard let winner else { return }
        if missedPongs >= Self.missedPongLimit { return dropped() }
        missedPongs += 1
        winner.ping { [weak self, weak winner] in
            guard let self, let winner, winner === self.winner else { return }
            self.missedPongs = 0
            self.lastSeen = self.clock.now
        }
        schedulePing()
    }

    // MARK: Discovery

    private func startBrowsing() {
        guard running, browser == nil else { return }
        browser = dial.browse(serviceName: record.serviceName) { [weak self] endpoints in
            self?.bonjourChanged(endpoints)
        }
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        // Forgotten so a restarted browse's first report counts as news.
        bonjour = []
    }

    private func bonjourChanged(_ endpoints: [NWEndpoint]) {
        let added = endpoints.filter { !bonjour.contains($0) }
        bonjour = endpoints
        guard running, winner == nil, !added.isEmpty else { return }
        if raceTimer != nil {
            for endpoint in added { dialCandidate("bonjour:\(endpoint)", endpoint) }
        } else {
            race()
        }
    }

    /// A new network is the best moment to try again, so the backoff restarts at its first
    /// step and a link waiting one out races now.
    private func pathChanged() {
        guard running else { return }
        attempt = 0
        if winner == nil, raceTimer == nil { race() }
    }

    // MARK: Plumbing

    private func resolve(_ id: Int, _ result: Result<HostReply, HostLinkError>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result)
    }

    private func failPending() {
        for id in pending.keys.sorted() { resolve(id, .failure(.offline)) }
    }

    private func cancelRacers() {
        let doomed = racers.values
        racers = [:]
        for connection in doomed where connection !== winner { connection.cancel() }
    }

    private func teardown() {
        capabilities = nil
        cancelRacers()
        winner?.cancel()
        winner = nil
        for timer in [raceTimer, retryTimer, pingTimer] { timer?.cancel() }
        raceTimer = nil
        retryTimer = nil
        pingTimer = nil
        stopBrowsing()
        failPending()
        detachChannels()
    }

    /// `host:port`, with an IPv6 literal optionally bracketed. The last colon splits, so an
    /// unbracketed IPv6 address still parses.
    static func endpoint(from text: String) -> NWEndpoint? {
        guard let colon = text.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(text[text.index(after: colon)...]))
        else { return nil }
        let host = text[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    /// What a win makes of the stored list: the address that just answered first, then the
    /// host's own advertised list (its ranking: tailnet first), then what was stored, without
    /// repeats, at most `HostRecord.maxEndpoints`.
    ///
    /// **A LAN address and a tailnet address both survive the cap** when the inputs hold both.
    /// A plain prefix would not promise that: a host with two VM bridges ranked between them,
    /// or a controller whose winner and stored list are all LAN, could push the one tailnet
    /// address off the end — and that is the one address that still works after the laptop
    /// leaves the room (spec §3.3). Loopback from the host or the winner is dropped (it names
    /// this Mac anywhere else); a stored entry is kept as the user or pairing put it there.
    static func mergedEndpoints(won: String?, advertised: [String], stored: [String]) -> [String] {
        var ordered: [String] = []
        for text in [won].compactMap({ $0 }) + advertised where !isLoopback(text) && !ordered.contains(text) {
            ordered.append(text)
        }
        for text in stored where !ordered.contains(text) { ordered.append(text) }
        guard ordered.count > HostRecord.maxEndpoints else { return ordered }

        let tailnet = { (text: String) in HostEndpoints.isCGNAT(hostPart(text)) }
        var kept = Set([ordered.first(where: tailnet), ordered.first(where: { !tailnet($0) })]
            .compactMap { $0 })
        for text in ordered where kept.count < HostRecord.maxEndpoints { kept.insert(text) }
        return ordered.filter(kept.contains)
    }

    /// `host` out of `host:port`, brackets off an IPv6 literal.
    private static func hostPart(_ text: String) -> String {
        guard let colon = text.lastIndex(of: ":") else { return text }
        return text[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// A loopback address names *this* Mac on any other network, so it is never learned.
    private static func isLoopback(_ text: String) -> Bool {
        guard case .hostPort(let host, _) = endpoint(from: text) else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }
}

// MARK: - Network

/// The real `HostLinkDialing`: `HostTransport`'s TLS-PSK WebSocket, `NWBrowser`, and
/// `NWPathMonitor`, each delivering on the main queue.
struct NetworkHostDialer: HostLinkDialing {
    /// Nonisolated for the reason `SystemHostLinkClock.init` is.
    nonisolated init() {}

    func connection(to endpoint: NWEndpoint, key: FleetDeviceKey) -> HostLinkConnection {
        NetworkHostConnection(endpoint: endpoint, key: key)
    }

    func browse(serviceName: String, onChange: @escaping ([NWEndpoint]) -> Void) -> HostLinkCancellable {
        let browser = NWBrowser(for: .bonjour(type: HostLink.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let matches = results.map(\.endpoint).filter {
                // Only this host: any other Flight Deck host would refuse our key anyway,
                // and dialling it is noise in the race.
                if case .service(let name, _, _, _) = $0 { return name == serviceName }
                return false
            }
            MainActor.assumeIsolated { onChange(matches) }
        }
        browser.start(queue: .main)
        return Handle { browser.cancel() }
    }

    func watchPath(onChange: @escaping () -> Void) -> HostLinkCancellable {
        let monitor = NWPathMonitor()
        let baseline = Baseline()
        monitor.pathUpdateHandler = { path in
            MainActor.assumeIsolated {
                // The first report is the path the link started on, not a change.
                guard baseline.seen else { baseline.seen = true; return }
                guard path.status == .satisfied else { return }
                onChange()
            }
        }
        monitor.start(queue: .main)
        return Handle { monitor.cancel() }
    }

    /// Main-confined: the monitor delivers on `.main`.
    private final class Baseline { var seen = false }

    private final class Handle: HostLinkCancellable {
        private var onCancel: (() -> Void)?
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel?(); onCancel = nil }
    }
}

@MainActor
final class NetworkHostConnection: HostLinkConnection {
    var onReady: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClosed: (() -> Void)?
    /// Whole binary messages: `ChannelMux` frames (HostLinkChannels.swift). Before these,
    /// every message was decoded as text, so a binary one surfaced as an unreadable frame.
    var onBinary: ((Data) -> Void)?

    private let connection: NWConnection
    private var ended = false

    init(endpoint: NWEndpoint, key: FleetDeviceKey) {
        connection = NWConnection(to: HostTransport.endpoint(for: endpoint),
                                  using: HostTransport.clientParameters(key: key))
    }

    var remoteAddress: String? {
        guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint
        else { return nil }
        // Bracketed, as a paired IPv6 address is, so the stored text splits at its last colon
        // and dedupes against the same address written by pairing or by the host's helloAck.
        if case .ipv6 = host { return "[\(host)]:\(port.rawValue)" }
        return "\(host):\(port.rawValue)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// One `ChannelMux` frame. Ordered with other calls made here, but `HostLink` reaches this
    /// through a main-queue hop, so it is not ordered with text it sends directly.
    func send(binary: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "channel", metadata: [metadata])
        connection.send(content: binary, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    func ping(onPong: @escaping () -> Void) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { error in
            guard error == nil else { return }
            MainActor.assumeIsolated { onPong() }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// Silences every callback first: the link cancels losers and dead winners itself and
    /// must not hear about it as a fresh close.
    func cancel() {
        ended = true
        onReady = nil
        onText = nil
        onClosed = nil
        onBinary = nil
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
            receive()
        // `.waiting` too: NWConnection parks a refused connect there and retries it forever,
        // which in a race is a candidate that never loses.
        case .failed, .waiting, .cancelled:
            end()
        default:
            break
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                if error != nil { return self.end() }
                let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata)?.opcode
                if let data, !data.isEmpty, opcode == .binary {
                    self.onBinary?(data)
                } else if let data, !data.isEmpty {
                    self.onText?(String(decoding: data, as: UTF8.self))
                } else if complete, context?.isFinal ?? true {
                    return self.end()
                }
                self.receive()
            }
        }
    }

    private func end() {
        guard !ended else { return }
        let closed = onClosed
        cancel()
        closed?()
    }
}
