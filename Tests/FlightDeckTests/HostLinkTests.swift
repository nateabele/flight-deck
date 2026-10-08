import FleetKit
import Foundation
import HostKit
import Network
import XCTest
@testable import FlightDeck

/// Polls `condition` every 50 ms for up to `timeout`. For `@MainActor` tests, which must not
/// block the main thread in `wait(for:)`.
@MainActor
func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("condition never held", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

/// Time that moves only when told to, so backoff, liveness and request timeouts are stepped
/// rather than waited out.
@MainActor
final class ManualHostLinkClock: HostLinkClock {
    private(set) var now: Date
    private var timers: [Timer] = []

    /// `now` is where time starts: the infra harness starts it at its own fixture date, so
    /// the clock the Reaper reads and the one its machines were stamped with agree.
    init(now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) { self.now = now }

    final class Timer: HostLinkCancellable {
        let due: Date
        let fire: @MainActor () -> Void
        var cancelled = false
        init(due: Date, fire: @escaping @MainActor () -> Void) { self.due = due; self.fire = fire }
        func cancel() { cancelled = true }
    }

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> HostLinkCancellable {
        let timer = Timer(due: now.addingTimeInterval(delay), fire: fire)
        timers.append(timer)
        return timer
    }

    /// Fires every timer due by the new time in deadline order, including ones scheduled by
    /// a timer that fired along the way.
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = timers.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            next.cancelled = true
            next.fire()
        }
        now = target
        timers.removeAll { $0.cancelled }
    }
}

// MARK: - Against a real in-process hostd

@MainActor
final class HostLinkTests: XCTestCase {
    func makeServer(_ key: FleetDeviceKey) async throws -> (DarwinHostServer, NWEndpoint.Port, URL) {
        let root = URL(fileURLWithPath: "/tmp/fdl-\(UUID().uuidString.prefix(6))")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let s = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        return (s, try await s.start(), root)
    }

    func testGoesOnlineAndAnswersInfo() async throws {
        let key = FleetDeviceKey.mint(); let (s, port, _) = try await makeServer(key); defer { s.stop() }
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none", endpoints: ["127.0.0.1:\(port)"], platform: nil, pairedAt: Date()), key: key, controllerName: "test")
        let online = expectation(description: "online")
        link.onStateChange = { if case .online = $0 { online.fulfill() } }
        link.start(); await fulfillment(of: [online], timeout: 10)
        XCTAssertEqual(link.state, .online(hostName: "loop"))
        guard case .hostInfo(let info) = try await link.request(.hostInfo) else { return XCTFail() }
        XCTAssertEqual(info.hostName.isEmpty, false); link.stop()
    }

    /// Review Focus 1: the first stored endpoint is dead; the link must reach the live one.
    func testReconnectsWhenStoredEndpointIsStale() async throws {
        let key = FleetDeviceKey.mint(); let (s, port, _) = try await makeServer(key); defer { s.stop() }
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none",
                                          endpoints: ["127.0.0.1:1", "127.0.0.1:\(port)"], platform: nil, pairedAt: Date()), key: key, controllerName: "test")
        let online = expectation(description: "online"); online.assertForOverFulfill = false
        link.onStateChange = { if case .online = $0 { online.fulfill() } }
        link.start(); await fulfillment(of: [online], timeout: 10); link.stop()
    }

    func testServerStopMarksOfflineAndRestartRecovers() async throws {
        let key = FleetDeviceKey.mint(); var (s, port, root) = try await makeServer(key)
        let clock = ManualHostLinkClock()
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none", endpoints: ["127.0.0.1:\(port)"], platform: nil, pairedAt: Date()), key: key, controllerName: "test", clock: clock)
        var states: [HostLinkState] = []; link.onStateChange = { states.append($0) }
        link.start(); try await waitUntil { states.contains { if case .online = $0 { true } else { false } } }
        s.stop(); try await waitUntil { states.last.map { if case .offline = $0 { true } else { false } } ?? false }
        s = DarwinHostServer(root: root, port: port, hostName: { "loop" }); _ = try await s.start()
        clock.advance(by: 1)   // first backoff step is 1 s
        try await waitUntil { if case .online = states.last { true } else { false } }
        s.stop(); link.stop()
        _ = root
    }

    func testRequestWhileOfflineFailsFast() async throws {
        let key = FleetDeviceKey.mint()
        let link = HostLink(record: .init(slot: key.slot, name: "x", serviceName: "none", endpoints: ["127.0.0.1:1"], platform: nil, pairedAt: Date()), key: key, controllerName: "t")
        do { _ = try await link.request(.hostInfo); XCTFail() } catch { XCTAssertEqual(error as? HostLinkError, .offline) }
    }

    /// A Mac host advertises under `DarwinHostServer.serviceType`; a link browsing anything
    /// else would never find one.
    func testBrowsesTheTypeTheMacHostAdvertises() {
        XCTAssertEqual(HostLink.bonjourType, DarwinHostServer.serviceType)
    }
}

// MARK: - Against a scripted network

@MainActor
final class FakeHostConnection: HostLinkConnection {
    var onReady: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClosed: (() -> Void)?
    var remoteAddress: String?
    let endpoint: NWEndpoint
    private(set) var sent: [String] = []
    private(set) var pongs: [() -> Void] = []
    private(set) var cancelled = false

    init(endpoint: NWEndpoint) { self.endpoint = endpoint }

    func start() {}
    func send(_ text: String) { sent.append(text) }
    func ping(onPong: @escaping () -> Void) { pongs.append(onPong) }
    func cancel() { cancelled = true; onReady = nil; onText = nil; onClosed = nil }

    func say(_ frame: HostServerFrame) { onText?(try! HostWire.encode(frame)) }
    func hostClosed() { let closed = onClosed; cancel(); closed?() }
    /// The ids of the requests sent so far, in order.
    var requestIDs: [Int] {
        sent.compactMap {
            guard case .request(let id, _) = try? HostWire.decode(HostClientFrame.self, from: $0) else { return nil }
            return id
        }
    }
}

@MainActor
final class FakeHostDialer: HostLinkDialing {
    private(set) var connections: [FakeHostConnection] = []
    private(set) var browses = 0
    var onBrowse: (([NWEndpoint]) -> Void)?
    var onPath: (() -> Void)?

    final class Handle: HostLinkCancellable {
        let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    func connection(to endpoint: NWEndpoint, key: FleetDeviceKey) -> HostLinkConnection {
        let connection = FakeHostConnection(endpoint: endpoint)
        connections.append(connection)
        return connection
    }

    func browse(serviceName: String, onChange: @escaping ([NWEndpoint]) -> Void) -> HostLinkCancellable {
        browses += 1
        onBrowse = onChange
        return Handle { [weak self] in self?.onBrowse = nil }
    }

    func watchPath(onChange: @escaping () -> Void) -> HostLinkCancellable {
        onPath = onChange
        return Handle { [weak self] in self?.onPath = nil }
    }
}

@MainActor
final class HostLinkBehaviourTests: XCTestCase {
    let key = FleetDeviceKey.mint()
    let clock = ManualHostLinkClock()
    let dialer = FakeHostDialer()

    func makeLink(endpoints: [String] = ["10.0.0.5:47410"]) -> HostLink {
        HostLink(record: .init(slot: key.slot, name: "mini", serviceName: "mini", endpoints: endpoints,
                               platform: nil, pairedAt: Date()),
                 key: key, controllerName: "test", dial: dialer, clock: clock)
    }

    /// The `i`th connection dialled, failing (not trapping) when there is none, so one wrong
    /// count fails its own test instead of crashing the rest of the run.
    func dialed(_ i: Int, file: StaticString = #filePath, line: UInt = #line) -> FakeHostConnection {
        guard dialer.connections.indices.contains(i) else {
            XCTFail("no dial #\(i); \(dialer.connections.count) so far", file: file, line: line)
            return FakeHostConnection(endpoint: .hostPort(host: "0.0.0.0", port: 1))
        }
        return dialer.connections[i]
    }

    func ack(_ c: FakeHostConnection) {
        c.onReady?()
        c.say(.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"))
    }

    func online(_ link: HostLink) -> FakeHostConnection {
        link.start()
        let c = dialed(dialer.connections.count - 1)
        ack(c)
        XCTAssertEqual(link.state, .online(hostName: "mini"))
        return c
    }

    func testHelloNamesTheController() throws {
        let link = makeLink()
        link.start()
        dialed(0).onReady?()
        XCTAssertEqual(try HostWire.decode(HostClientFrame.self, from: dialed(0).sent[0]),
                       .hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "test"))
    }

    func testThreeMissedPongsGoOfflineAndReconnect() {
        let link = makeLink()
        let c = online(link)
        clock.advance(by: 45)
        XCTAssertEqual(c.pongs.count, 3)
        XCTAssertEqual(link.state, .online(hostName: "mini"), "three pings out is not yet three missed")
        clock.advance(by: 15)
        XCTAssertEqual(link.state, .offline(lastSeen: clock.now.addingTimeInterval(-60)))
        XCTAssertTrue(c.cancelled)
        clock.advance(by: 1)
        XCTAssertEqual(dialer.connections.count, 2, "redials after the first backoff step")
    }

    func testAnsweredPingsKeepTheLinkOnline() {
        let link = makeLink()
        let c = online(link)
        for _ in 0..<10 {
            clock.advance(by: 15)
            c.pongs.last?()
        }
        XCTAssertEqual(link.state, .online(hostName: "mini"))
        XCTAssertEqual(dialer.connections.count, 1)
    }

    func testMajorMismatchRefusesAndStopsRetrying() {
        let link = makeLink()
        link.start()
        dialed(0).onReady?()
        dialed(0).say(.refused(reason: .majorVersionMismatch(host: ProtocolVersion(major: 2, minor: 0))))
        XCTAssertEqual(link.state, .refused("Update Flight Deck on mini"))
        clock.advance(by: 300)
        dialer.onPath?()
        XCTAssertEqual(dialer.connections.count, 1)
        XCTAssertNil(dialer.onBrowse)
    }

    func testPendingRequestFailsOfflineWhenTheLinkDrops() async throws {
        let link = makeLink()
        let c = online(link)
        let request = Task { try await link.request(.hostInfo) }
        try await waitUntil { c.requestIDs.count == 1 }
        c.hostClosed()
        do { _ = try await request.value; XCTFail() } catch { XCTAssertEqual(error as? HostLinkError, .offline) }
        XCTAssertEqual(link.state, .offline(lastSeen: clock.now))
    }

    func testRequestTimesOutAfterTenSeconds() async throws {
        let link = makeLink()
        let c = online(link)
        let request = Task { try await link.request(.hostInfo) }
        try await waitUntil { c.requestIDs.count == 1 }
        clock.advance(by: 9)
        XCTAssertEqual(link.state, .online(hostName: "mini"))
        clock.advance(by: 1)
        do { _ = try await request.value; XCTFail() } catch { XCTAssertEqual(error as? HostLinkError, .timedOut) }
    }

    func testRepliesAndErrorsAreMatchedById() async throws {
        let link = makeLink()
        let c = online(link)
        let first = Task { try await link.request(.hostInfo) }
        try await waitUntil { c.requestIDs.count == 1 }
        let second = Task { try await link.request(.hostInfo) }
        try await waitUntil { c.requestIDs.count == 2 }
        let ids = c.requestIDs
        XCTAssertEqual(ids[1], ids[0] + 1)
        let info = HostInfo(hostName: "mini", platform: "Linux", osVersion: "6", arch: "arm64",
                            hostdVersion: "0.1.0", xcode: [], docker: nil, diskFreeBytes: 1)
        c.say(.error(id: ids[1], code: "unsupported", message: "nope"))
        c.say(.reply(id: ids[0], .hostInfo(info)))
        let reply = try await first.value
        XCTAssertEqual(reply, .hostInfo(info))
        do { _ = try await second.value; XCTFail() } catch {
            XCTAssertEqual(error as? HostLinkError, .remote(code: "unsupported", message: "nope"))
        }
    }

    func testANewWinningAddressIsLearnedButStoredAndLoopbackOnesAreNot() {
        var learned: [[String]] = []
        let link = makeLink(endpoints: ["10.0.0.5:47410", "10.0.0.6:47410"])
        link.onEndpointsChanged = { learned.append($0) }
        link.start()
        dialed(0).remoteAddress = "10.0.0.5:47410"
        ack(dialed(0))
        XCTAssertEqual(learned, [])
        XCTAssertTrue(dialed(1).cancelled, "the losing racer is cancelled")

        dialed(0).hostClosed()
        clock.advance(by: 1)
        dialed(2).remoteAddress = "127.0.0.1:47410"
        ack(dialed(2))
        XCTAssertEqual(learned, [])

        dialed(2).hostClosed()
        clock.advance(by: 1)
        dialed(4).remoteAddress = "192.168.1.9:47410"
        ack(dialed(4))
        XCTAssertEqual(learned, [["192.168.1.9:47410", "10.0.0.5:47410", "10.0.0.6:47410"]])
    }

    /// The winner first, then what the host says about itself, then what was stored — and
    /// when that overflows the cap, a LAN address and a tailnet address both survive, because
    /// those two are the pair that covers "in the room" and "anywhere else".
    func testMergeKeepsTheWinnerAndBothALANAndATailnetAddress() {
        XCTAssertEqual(
            HostLink.mergedEndpoints(won: "192.168.1.9:47410",
                                     advertised: ["100.100.1.2:47410", "192.168.1.9:47410"], stored: []),
            ["192.168.1.9:47410", "100.100.1.2:47410"])
        XCTAssertEqual(
            HostLink.mergedEndpoints(won: "10.0.0.9:47410",
                                     advertised: ["10.1.1.1:47410", "10.2.2.2:47410", "10.3.3.3:47410",
                                                  "100.100.1.2:47410"],
                                     stored: ["box.local:47410"]),
            ["10.0.0.9:47410", "10.1.1.1:47410", "10.2.2.2:47410", "100.100.1.2:47410"])
        XCTAssertEqual(
            HostLink.mergedEndpoints(won: "100.100.1.2:47410", advertised: [],
                                     stored: ["10.0.0.5:47410"]),
            ["100.100.1.2:47410", "10.0.0.5:47410"])
        XCTAssertEqual(
            HostLink.mergedEndpoints(won: "127.0.0.1:47410", advertised: ["127.0.0.1:47410"],
                                     stored: ["10.0.0.5:47410"]),
            ["10.0.0.5:47410"], "loopback names this Mac, never the host")
        XCTAssertEqual(HostRecord.maxEndpoints, 4)
    }

    /// A stale stored address refused at once must not end every race before Bonjour finds
    /// the host: a service appearing mid-backoff races immediately.
    func testBonjourResultDuringBackoffRacesAtOnce() {
        let link = makeLink()
        link.start()
        dialed(0).hostClosed()
        XCTAssertEqual(link.state, .offline(lastSeen: nil))
        let service = NWEndpoint.service(name: "mini", type: HostLink.bonjourType, domain: "local.", interface: nil)
        dialer.onBrowse?([service])
        XCTAssertEqual(dialer.connections.map(\.endpoint).last, service)
        ack(dialed(dialer.connections.count - 1))
        XCTAssertEqual(link.state, .online(hostName: "mini"))
        XCTAssertNil(dialer.onBrowse, "the browse stops once online")
    }

    func testPathChangeDuringBackoffRacesAtOnceAndResetsTheBackoff() {
        let link = makeLink()
        link.start()
        dialed(0).hostClosed()          // backoff 1 s
        clock.advance(by: 1)
        dialed(1).hostClosed()          // backoff 2 s
        dialer.onPath?()
        XCTAssertEqual(dialer.connections.count, 3, "raced without waiting out the 2 s step")
        dialed(2).hostClosed()
        clock.advance(by: 1)
        XCTAssertEqual(dialer.connections.count, 4, "the backoff restarted at 1 s")
    }

    func testRaceWithNoAnswerTimesOutAndBacksOff() {
        let link = makeLink()
        link.start()
        XCTAssertEqual(link.state, .connecting)
        clock.advance(by: 8)
        XCTAssertEqual(link.state, .offline(lastSeen: nil))
        XCTAssertTrue(dialed(0).cancelled)
        clock.advance(by: 1)
        XCTAssertEqual(dialer.connections.count, 2)
    }

    func testStopFailsPendingAndStopsEverything() async throws {
        let link = makeLink()
        let c = online(link)
        let request = Task { try await link.request(.hostInfo) }
        try await waitUntil { c.requestIDs.count == 1 }
        link.stop()
        do { _ = try await request.value; XCTFail() } catch { XCTAssertEqual(error as? HostLinkError, .offline) }
        XCTAssertTrue(c.cancelled)
        XCTAssertNil(dialer.onPath)
        clock.advance(by: 120)
        XCTAssertEqual(dialer.connections.count, 1)
    }
}

// MARK: - HostService

@MainActor
final class HostServiceTests: XCTestCase {
    var url: URL!
    let clock = ManualHostLinkClock()
    let dialer = FakeHostDialer()

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testStartWithNoHostsDoesNothing() async throws {
        let service = HostService(registry: HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore()),
                                  controllerName: "c", dial: dialer, clock: clock)
        service.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.statuses, [:])
        XCTAssertEqual(dialer.connections.count, 0)
        XCTAssertEqual(dialer.browses, 0)
    }

    func testOnlineHostLearnsItsAddressPlatformAndLastSeen() async throws {
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let record = try registry.add(key: .mint(), name: "mini", serviceName: "mini",
                                      endpoints: ["10.0.0.5:47410", "10.0.0.6:47410"])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        XCTAssertEqual(service.statuses[record.slot], .offline(lastSeen: nil), "listed before its key is read")
        try await waitUntil { dialer.connections.count == 2 }

        let c = dialer.connections[0]
        c.remoteAddress = "10.0.0.9:47410"
        c.onReady?()
        c.say(.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"))
        XCTAssertEqual(service.statuses[record.slot], .online(hostName: "mini"))
        XCTAssertEqual(registry.hosts[0].endpoints, ["10.0.0.9:47410", "10.0.0.5:47410", "10.0.0.6:47410"])
        XCTAssertEqual(registry.hosts[0].lastSeenAt, clock.now)

        // The first online asks `host.info` for the platform.
        try await waitUntil { c.requestIDs.count == 1 }
        c.say(.reply(id: c.requestIDs[0], .hostInfo(HostInfo(
            hostName: "mini", platform: "Linux", osVersion: "6", arch: "arm64", hostdVersion: "0.1.0",
            xcode: [], docker: nil, diskFreeBytes: 1))))
        try await waitUntil { registry.hosts[0].platform == "Linux" }

        let reloaded = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore()).hosts[0]
        XCTAssertEqual(reloaded.endpoints, ["10.0.0.9:47410", "10.0.0.5:47410", "10.0.0.6:47410"])
        XCTAssertEqual(reloaded.platform, "Linux")

        // The next race dials the learned address first.
        c.hostClosed()
        clock.advance(by: 1)
        XCTAssertEqual(dialer.connections.suffix(3).map(\.endpoint),
                       ["10.0.0.9:47410", "10.0.0.5:47410", "10.0.0.6:47410"].compactMap(HostLink.endpoint(from:)))
        service.forget(slot: record.slot)
    }

    /// Spec §3.3's "laptop moves to Tailscale": a host known only by its LAN address says in
    /// helloAck that it also has a tailnet one; that is stored; and when the LAN address goes
    /// stale the next race reaches the host through the advertised address, with no re-pair.
    func testAdvertisedTailnetAddressReachesTheHostOnceTheLANOneGoesStale() async throws {
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let record = try registry.add(key: .mint(), name: "mini", serviceName: "mini",
                                      endpoints: ["192.168.1.9:47410"])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        try await waitUntil { dialer.connections.count == 1 }

        let lan = dialer.connections[0]
        lan.remoteAddress = "192.168.1.9:47410"
        lan.onReady?()
        lan.say(.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini",
                          endpoints: ["100.100.1.2:47410", "192.168.1.9:47410"]))
        XCTAssertEqual(registry.hosts[0].endpoints, ["192.168.1.9:47410", "100.100.1.2:47410"])
        XCTAssertEqual(HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore()).hosts[0].endpoints,
                       ["192.168.1.9:47410", "100.100.1.2:47410"], "persisted")

        // Off the LAN: the stored address is refused, the advertised one answers.
        lan.hostClosed()
        clock.advance(by: 1)
        let race = Array(dialer.connections.suffix(2))
        XCTAssertEqual(race.map(\.endpoint),
                       ["192.168.1.9:47410", "100.100.1.2:47410"].compactMap(HostLink.endpoint(from:)))
        race[0].hostClosed()
        race[1].onReady?()
        race[1].say(.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"))
        XCTAssertEqual(service.statuses[record.slot], .online(hostName: "mini"))
        service.forget(slot: record.slot)
    }

    func testAHostWithNoKeyIsShownAsNeedingARepair() async throws {
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let record = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        registry.secrets.remove(slot: record.slot)
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        try await waitUntil { if case .refused = service.statuses[record.slot] { true } else { false } }
        XCTAssertEqual(service.statuses[record.slot], .refused("Pair mini again: its key is missing"))
        XCTAssertEqual(dialer.connections.count, 0)
    }

    func testForgetStopsTheLinkAndUnpairs() async throws {
        let secrets = InMemoryHostSecretStore()
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let record = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        try await waitUntil { dialer.connections.count == 1 }
        service.forget(slot: record.slot)
        XCTAssertTrue(dialer.connections[0].cancelled)
        XCTAssertNil(service.statuses[record.slot])
        XCTAssertEqual(registry.hosts, [])
        XCTAssertNil(secrets.secret(for: record.slot))
        clock.advance(by: 60)
        XCTAssertEqual(dialer.connections.count, 1)
    }

    func testInfoForAnUnknownNameListsThePairedOnes() async throws {
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        _ = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        do { _ = try await service.info(name: "maxi"); XCTFail() } catch {
            XCTAssertEqual(error as? HostLookupError, .unknown(available: ["mini"]))
        }
        do { _ = try await service.info(name: "mini"); XCTFail() } catch {
            XCTAssertEqual(error as? HostLinkError, .offline)
        }
    }

    func testPairingAddressesDefaultToThePairingPort() {
        XCTAssertEqual(HostService.pairingEndpoint("box.local"), HostLink.endpoint(from: "box.local:47411"))
        XCTAssertEqual(HostService.pairingEndpoint(" 10.0.0.7:5000 "), HostLink.endpoint(from: "10.0.0.7:5000"))
        XCTAssertEqual(HostService.pairingEndpoint("fd7a::1"), .hostPort(host: "fd7a::1", port: 47411))
        XCTAssertEqual(HostService.pairingEndpoint("[fd7a::1]:6000"), .hostPort(host: "fd7a::1", port: 6000))
        XCTAssertNil(HostService.pairingEndpoint(""))
    }
}
