import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// `FleetService`'s `delegate` arm over real sockets: a local CLI's stream arrives frame by
/// frame with its caller's token honoured, and a paired phone is refused (ruling 4).
@MainActor
final class DelegationFleetServiceTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient?
    private var mini: FakeHostLink!

    override func setUp() async throws {
        harness = FleetTestHarness()
        let hosts = FakeHosts()
        mini = FakeHostLink(name: "mini")
        hosts.links["mini"] = mini
        let sync = FakeSync()
        harness.service.delegation = DelegationService(registry: RunRegistry(file: nil), dependencies: .init(
            hosts: hosts, preflight: FakePreflight(), snapshots: sync, bundles: sync, results: FakeResults(),
            config: FakeConfig(), worktrees: FakeWorktrees(), sessionTitle: { _ in "alpha" },
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("fd-dfs-\(UUID().uuidString)")))
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness.service.stop()
        harness = nil
    }

    func testALocalRunStreamsEveryFrameToItsEnd() async throws {
        let path = "/tmp/fddf-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
        let client = FleetClient(localCaller: nil)
        self.client = client
        let ended = expectation(description: "delegateExit")
        var cid = -1
        var frames: [ServerFrame] = []
        client.onFrame = { frame in
            if case .snapshot = frame {
                cid = client.send(FleetRequest.delegate(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"]))))
            }
            guard frame.correlationID == cid else { return }
            frames.append(frame)
            if case .delegateStarted = frame {
                self.mini.emit("h1", .output(stream: .stdout, offset: 0, data: Data("a".utf8)))
                self.mini.emit("h1", .output(stream: .stdout, offset: 1, data: Data("b".utf8)))
                self.mini.emit("h1", .exited(.code(4)))
            }
            if case .delegateExit = frame { ended.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(frames.count, 4, "\(frames)")
        XCTAssertEqual(frames.last, .delegateExit(cid: cid, status: 4))
    }

    /// Ruling 4: delegation is local-only. A phone has no tab to own a run.
    func testAPairedPhoneIsRefused() async throws {
        let port = try await harness.start()
        let client = FleetClient(key: harness.key)
        self.client = client
        let refused = expectation(description: "refused")
        var cid = -1
        var reply: ServerFrame?
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(FleetRequest.delegate(.ps)) }
            if frame.correlationID == cid { reply = frame; refused.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(reply, .err(cid: cid, code: "out_of_scope"))
        XCTAssertTrue(mini.requests.isEmpty)
    }

    /// A tab's token reaches `DelegationService` as its session: another tab's run is not found.
    func testATabsTokenScopesItsRuns() async throws {
        let path = "/tmp/fddf-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
        let other = harness.service.delegation!
        let started = expectation(description: "human run")
        other.handle(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["x"], detach: true)),
                     caller: .session(UUID()), cid: 1) { if case .delegateStarted = $0 { started.fulfill() } }
        await fulfillment(of: [started], timeout: 5)

        let token = ControlEnvironment.token(for: UUID(), secret: harness.service.controlSecret)
        let client = FleetClient(localCaller: token)
        self.client = client
        let answered = expectation(description: "ps")
        var cid = -1
        var rows: [WireDelegateRunRow]?
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(FleetRequest.delegate(.ps)) }
            if case .delegateRuns(let got, let runs) = frame, got == cid { rows = runs; answered.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(rows, [])
    }
}
