import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// A real `FleetService` on a local control socket, holding a `HostService` over an in-memory
/// registry that is never started — so no host has a live link, which is the state every
/// refusal below is about.
@MainActor
final class FleetServiceHarness {
    let fleet: FleetTestHarness
    let hosts: HostService
    let path = "/tmp/fdhost-\(UUID().uuidString.prefix(8)).sock"
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("hosts-\(UUID().uuidString).json")

    init(hosts names: [String]) throws {
        let registry = HostRegistry(fileURL: file, secrets: InMemoryHostSecretStore())
        for name in names {
            try registry.add(key: .mint(), name: name, serviceName: name, endpoints: [])
        }
        hosts = HostService(registry: registry, controllerName: "controller")
        fleet = FleetTestHarness(hosts: hosts)
    }

    func start() async throws { try await fleet.service.startLocal(at: URL(fileURLWithPath: path)) }

    func stop() {
        fleet.service.stop()
        unlink(path)
        try? FileManager.default.removeItem(at: file)
    }

    /// One request over the socket, as an unscoped local caller; returns its reply.
    func request(_ request: FleetRequest) async throws -> ServerFrame {
        let client = FleetClient(localCaller: nil)
        defer { client.disconnect() }
        var cid: Int?
        var reply: ServerFrame?
        let ready = XCTestExpectation(description: "snapshot")
        ready.assertForOverFulfill = false
        let answered = XCTestExpectation(description: "reply")
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            if let cid, frame.correlationID == cid { reply = frame; answered.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await XCTWaiter().fulfillment(of: [ready], timeout: 5)
        cid = client.send(request)
        await XCTWaiter().fulfillment(of: [answered], timeout: 5)
        return try XCTUnwrap(reply, "no reply to \(request)")
    }

    /// The brief's one-liner: stand up, ask once, tear down.
    static func request(_ request: FleetRequest, hosts names: [String]) async throws -> ServerFrame {
        let harness = try FleetServiceHarness(hosts: names)
        try await harness.start()
        defer { harness.stop() }
        return try await harness.request(request)
    }

    /// `flightdeck <args>` over the real `LocalFleetTransport`, the way `main.swift` runs it.
    func run(_ args: String...) async throws -> (code: Int32?, out: [String], err: [String]) {
        let transport = LocalFleetTransport(path: path, caller: nil)
        defer { transport.disconnect() }
        var code: Int32?
        var out: [String] = []
        var err: [String] = []
        let finished = XCTestExpectation(description: "runner finished")
        let runner = CLIRunner(
            invocation: try CLIArguments.parse(args), transport: transport,
            context: CLIContext(selfID: nil, cwd: "/", json: false, isTTY: true),
            out: { out.append($0) }, err: { err.append($0) },
            finish: { code = $0; finished.fulfill() },
            schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) })
        runner.run()
        await XCTWaiter().fulfillment(of: [finished], timeout: 5)
        return (code, out, err)
    }
}

@MainActor
final class HostCLITests: XCTestCase {
    // MARK: Wire

    func testHostListReplyRoundTrips() throws {
        let frame = ServerFrame.hostList(cid: 4, [WireHost(name: "mini", platform: "macOS", status: "online",
                                                           detail: nil, lastSeenAt: nil)])
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame)), frame)
        XCTAssertEqual(frame.correlationID, 4)
    }

    func testHostInfoReplyRoundTrips() throws {
        let frame = ServerFrame.hostInfo(cid: 6, WireHostInfo(
            name: "mini", hostName: "Mac-mini", platform: "macOS", osVersion: "26.1", arch: "arm64",
            hostdVersion: "1.0", xcode: ["26.0"], docker: nil, diskFreeBytes: 1_000))
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame)), frame)
        XCTAssertEqual(frame.correlationID, 6)
    }

    func testHostRequestsRoundTripUnderTheirOps() throws {
        for (request, op) in [(FleetRequest.hostList, "host.list"), (.hostInfo(name: "mini"), "host.info")] {
            let data = try JSONEncoder().encode(ClientFrame.req(cid: 2, request))
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), .req(cid: 2, request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["op"] as? String, op)
        }
    }

    /// The message is additive: an `err` without one keeps the exact bytes every older peer
    /// sends and reads, and one from an older Mac decodes with no message.
    func testAnErrWithoutAMessageKeepsItsOldShape() throws {
        let plain = try JSONEncoder().encode(ServerFrame.err(cid: 3, code: "x"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["t", "cid", "code"])
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: Data(#"{"t":"err","cid":3,"code":"x"}"#.utf8)),
                       .err(cid: 3, code: "x", message: nil))
        let worded = ServerFrame.err(cid: 3, code: "x", message: "why")
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(worded)), worded)
    }

    // MARK: Scope

    func testHostRequestsAreReadOnlyScope() {
        XCTAssertTrue(ControlScope.permits(.hostList, level: .readOnly, caller: .session(UUID())))
        XCTAssertTrue(ControlScope.permits(.hostInfo(name: "x"), level: .readOnly, caller: .session(UUID())))
        XCTAssertTrue(ControlScope.permits(.hostInfo(name: "x"), level: .ownSession, caller: .invalid))
    }

    // MARK: Service

    /// Review Focus 4: an unknown name errors with the available names, never a silent pick.
    func testHostInfoUnknownNameListsHosts() async throws {
        let reply = try await FleetServiceHarness.request(.hostInfo(name: "maxi"), hosts: ["mini", "mini-2"])
        XCTAssertEqual(reply, .err(cid: try XCTUnwrap(reply.correlationID), code: "unknown_host",
                                   message: "no host named maxi; paired: mini, mini-2"))
    }

    /// "mini" must never resolve to "mini-2" just because it is a prefix of it, nor the reverse.
    func testAPrefixIsNotAMatch() async throws {
        let reply = try await FleetServiceHarness.request(.hostInfo(name: "min"), hosts: ["mini", "mini-2"])
        guard case .err(_, "unknown_host", _) = reply else { return XCTFail("\(reply)") }
    }

    func testHostListReportsEveryPairedHostInRegistryOrder() async throws {
        let reply = try await FleetServiceHarness.request(.hostList, hosts: ["mini", "linux-box"])
        guard case .hostList(_, let rows) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(rows, [
            WireHost(name: "mini", platform: nil, status: "offline", detail: nil, lastSeenAt: nil),
            WireHost(name: "linux-box", platform: nil, status: "offline", detail: nil, lastSeenAt: nil),
        ])
    }

    func testAHostWithNoLinkIsOfflineAndNeverSeen() async throws {
        let reply = try await FleetServiceHarness.request(.hostInfo(name: "MINI"), hosts: ["mini"])
        guard case .err(_, let code, let message) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(code, "host_offline")
        // The registry's spelling, not the typed one: that is the name the user will see in `ls`.
        XCTAssertEqual(message, "mini is offline (never seen)")
    }

    func testAnOfflineHostSaysWhenItWasLastSeen() async throws {
        let harness = try FleetServiceHarness(hosts: ["mini"])
        var record = harness.hosts.registry.hosts[0]
        record.lastSeenAt = Date().addingTimeInterval(-245)
        harness.hosts.registry.update(record)
        try await harness.start()
        defer { harness.stop() }
        let reply = try await harness.request(.hostInfo(name: "mini"))
        XCTAssertEqual(reply, .err(cid: try XCTUnwrap(reply.correlationID), code: "host_offline",
                                   message: "mini is offline (last seen 4m ago)"))
    }

    // MARK: Projection

    func testARefusedHostReportsTheRefusalNotOffline() throws {
        let harness = try FleetServiceHarness(hosts: ["mini"])
        defer { harness.stop() }
        let slot = harness.hosts.registry.hosts[0].slot
        let refusal = HostProjection.refusal(
            for: HostLinkError.offline, name: "mini", registry: harness.hosts.registry,
            state: { $0 == slot ? .refused("Update Flight Deck on mini") : nil }, now: Date())
        XCTAssertEqual(refusal.code, "host_refused")
        XCTAssertEqual(refusal.message, "Update Flight Deck on mini")
        XCTAssertEqual(HostProjection.row(harness.hosts.registry.hosts[0], .refused("Update Flight Deck on mini")),
                       WireHost(name: "mini", platform: nil, status: "refused",
                                detail: "Update Flight Deck on mini", lastSeenAt: nil))
    }

    func testATimeoutHasItsOwnCode() throws {
        let harness = try FleetServiceHarness(hosts: ["mini"])
        defer { harness.stop() }
        let refusal = HostProjection.refusal(for: HostLinkError.timedOut, name: "mini",
                                             registry: harness.hosts.registry, state: { _ in nil }, now: Date())
        XCTAssertEqual(refusal.code, "host_timeout")
        XCTAssertEqual(refusal.message, "mini did not answer within 10s")
    }

    func testEveryLinkStateHasItsWireSpelling() throws {
        let harness = try FleetServiceHarness(hosts: ["mini"])
        defer { harness.stop() }
        let record = harness.hosts.registry.hosts[0]
        let states: [(HostLinkState, String)] = [
            (.online(hostName: "m"), "online"), (.offline(lastSeen: nil), "offline"),
            (.connecting, "connecting"), (.refused("r"), "refused"),
        ]
        for (state, spelling) in states {
            XCTAssertEqual(HostProjection.row(record, state).status, spelling)
        }
    }

    // MARK: CLI, end to end

    /// Unsorted on purpose: the names come back in registry (pairing) order, not alphabetised.
    func testTheCLIPrintsTheRefusalMessageAndExitsNonZero() async throws {
        let harness = try FleetServiceHarness(hosts: ["zeta", "alpha"])
        try await harness.start()
        defer { harness.stop() }
        let result = try await harness.run("host", "info", "maxi")
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(result.err, ["flightdeck: no host named maxi; paired: zeta, alpha"])
        XCTAssertEqual(result.out, [])
    }

    func testTheCLIPrintsTheHostTable() async throws {
        let harness = try FleetServiceHarness(hosts: ["mini", "linux-box"])
        try await harness.start()
        defer { harness.stop() }
        let result = try await harness.run("host", "ls")
        XCTAssertEqual(result.code, 0, "\(result.err)")
        XCTAssertEqual(result.out, ["""
            NAME       PLATFORM  STATUS   LAST SEEN
            mini       -         offline  never
            linux-box  -         offline  never
            """])
    }

    func testHostInfoPrintsKeyValueLines() {
        let text = CLIOutput.hostInfo(WireHostInfo(
            name: "mini", hostName: "Mac-mini", platform: "macOS", osVersion: "26.1", arch: "arm64",
            hostdVersion: "1.0", xcode: ["26.0", "16.4"], docker: nil, diskFreeBytes: 123_456_789_012))
        XCTAssertEqual(text, """
            name:      mini
            host:      Mac-mini
            platform:  macOS
            os:        26.1
            arch:      arm64
            hostd:     1.0
            xcode:     26.0, 16.4
            docker:    -
            disk free: 123.46 GB
            """)
    }

    func testTheHostTableShowsNowForOnlineAndTheRefusalReason() {
        let now = Date()
        let text = CLIOutput.table([
            WireHost(name: "mini", platform: "macOS", status: "online", detail: nil,
                     lastSeenAt: now.addingTimeInterval(-7200)),
            WireHost(name: "box", platform: "Linux", status: "refused", detail: "Update Flight Deck on box",
                     lastSeenAt: now.addingTimeInterval(-245)),
        ], now: now)
        let pad = String(repeating: " ", count: 28) // STATUS is as wide as the refusal cell, 34
        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "NAME  PLATFORM  STATUS\(pad)  LAST SEEN",
            "mini  macOS     online\(pad)  now",
            "box   Linux     refused: Update Flight Deck on box  4m ago",
        ])
    }
}
