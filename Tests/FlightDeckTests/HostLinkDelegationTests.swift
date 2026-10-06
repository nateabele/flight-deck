import FleetKit
import Foundation
import HostKit
import XCTest
@testable import FlightDeck

/// The hook delegation drives a host link through: events, the helloAck's capabilities,
/// per-request and idle timeouts, and `HostService.link(slot:)`.
@MainActor
final class HostLinkDelegationTests: XCTestCase {
    let key = FleetDeviceKey.mint()
    let clock = ManualHostLinkClock()
    let dialer = FakeHostDialer()

    private func makeLink() -> HostLink {
        HostLink(record: .init(slot: key.slot, name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"],
                               platform: nil, pairedAt: Date()),
                 key: key, controllerName: "test", dial: dialer, clock: clock)
    }

    private func online(_ link: HostLink, capabilities: [HostCapability] = [.hostInfo, .run, .sync]) -> FakeHostConnection {
        link.start()
        let c = dialer.connections[dialer.connections.count - 1]
        c.onReady?()
        c.say(.helloAck(protocolVersion: .current, capabilities: capabilities, hostName: "mini"))
        return c
    }

    /// Steps the clock with the host answering every ping, so a long step is only the
    /// request's timeout and never the link's liveness check.
    private func advance(_ c: FakeHostConnection, by seconds: TimeInterval) {
        var left = seconds
        while left > 0 {
            let step = min(5, left)
            clock.advance(by: step)
            c.pongs.last?()
            left -= step
        }
    }

    private final class Outcome { var result: Result<HostReply, Error>? }

    private func pending(_ link: HostLink, _ c: FakeHostConnection, timeout: TimeInterval,
                         progress: (@MainActor () -> Date)? = nil) async throws -> Outcome {
        let outcome = Outcome()
        let sent = c.requestIDs.count
        Task { @MainActor in
            do { outcome.result = .success(try await link.request(.delegation(.runCancel(runID: "r1")),
                                                                  timeout: timeout, progress: progress)) }
            catch { outcome.result = .failure(error) }
        }
        try await waitUntil { c.requestIDs.count == sent + 1 }
        return outcome
    }

    private func timedOut(_ outcome: Outcome) -> Bool {
        if case .failure(HostLinkError.timedOut)? = outcome.result { return true }
        return false
    }

    func testEventsReachOnEvent() {
        let link = makeLink()
        let c = online(link)
        var seen: [(String, RunEvent)] = []
        link.onEvent = { seen.append(($0, $1)) }
        c.say(.event(runID: "r1", .started(runID: "r1")))
        XCTAssertEqual(seen.map(\.0), ["r1"])
        XCTAssertEqual(seen.map(\.1), [.started(runID: "r1")])
    }

    func testCapabilitiesComeFromHelloAckAndGoWithTheConnection() {
        let link = makeLink()
        XCTAssertNil(link.capabilities)
        let c = online(link, capabilities: [.hostInfo, .run])
        XCTAssertEqual(link.capabilities, [.hostInfo, .run])
        c.hostClosed()
        XCTAssertNil(link.capabilities)
    }

    func testARequestTimesOutAfterItsOwnBound() async throws {
        let link = makeLink()
        let c = online(link)
        let outcome = try await pending(link, c, timeout: 30)
        advance(c, by: 29)
        await Task.yield()
        XCTAssertNil(outcome.result, "past the 10 s default, inside its own 30 s")
        advance(c, by: 1)
        try await waitUntil { outcome.result != nil }
        XCTAssertTrue(timedOut(outcome))
    }

    func testAnIdleTimeoutRunsFromTheLastProgress() async throws {
        let link = makeLink()
        let c = online(link)
        var last = clock.now
        let outcome = try await pending(link, c, timeout: 60, progress: { last })
        advance(c, by: 50)
        last = clock.now
        advance(c, by: 50)
        await Task.yield()
        XCTAssertNil(outcome.result, "100 s in, but only 50 s since the transfer last moved")
        advance(c, by: 10)
        try await waitUntil { outcome.result != nil }
        XCTAssertTrue(timedOut(outcome))
    }

    func testHostServiceHandsOutItsLinkUntilForgotten() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let record = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        XCTAssertNil(service.link(slot: record.slot))
        service.start()
        try await waitUntil { service.link(slot: record.slot) != nil }
        service.forget(slot: record.slot)
        XCTAssertNil(service.link(slot: record.slot))
    }

    func testTheDirectoryRefusesAnUnreachableHostAsHostOfflineAndReportsItComingUp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let record = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        let directory = LiveHostDirectory(hostService: service, mirrors: FileManager.default.temporaryDirectory)
        var cameUp = 0
        directory.onHostOnline = { cameUp += 1 }
        do { _ = try directory.link(named: "mini"); XCTFail() } catch let error as DelegationError {
            XCTAssertEqual(error.code, "host_offline")
            XCTAssertEqual(error.message, "mini is offline (never seen)")
        }
        service.start()
        try await waitUntil { dialer.connections.count == 1 }
        let link = try directory.link(named: "mini")
        XCTAssertFalse(link.isConnected)
        let c = dialer.connections[0]
        c.onReady?()
        c.say(.helloAck(protocolVersion: .current, capabilities: [.hostInfo, .run], hostName: "mini"))
        try await waitUntil { cameUp == 1 }
        XCTAssertTrue(link.isConnected)
        service.forget(slot: record.slot)
    }

    /// Ruling 21's point: a finished run's output is on this Mac, so `logs` answers with the
    /// host offline, and nothing is asked of it.
    func testLogsOfAFinishedRunAnswerFromTheCopyWithTheHostOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logs-offline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hosts.json")
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let host = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let hostService = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        hostService.start()
        try await waitUntil { hostService.link(slot: host.slot) != nil }

        let runs = RunRegistry(file: nil)
        let id = runs.mintID()
        let mirrors = root.appendingPathComponent("delegation")
        let mirror = RunMirror(url: LiveHostLink.mirrorURL(in: mirrors, localID: id))
        mirror.reset(origin: 0)
        mirror.record(.started(runID: "h1"))
        mirror.append(RunMirror.Chunk(stream: .stdout, offset: 0, data: Data("built ok\n".utf8)))
        mirror.record(.exited(.code(0)))

        runs.add(DelegatedRun(id: id, hostRunID: "h1", host: "mini", owner: nil, kind: .run, command: "make",
                              recipe: nil, state: .exited, status: 0, ports: [], startedAt: Date(), worktree: "/w",
                              snapshot: nil, applyMode: .review, request: WireDelegateRun(cwd: "/w"),
                              resultCommit: nil, resultBundle: nil))
        let service = DelegationService(registry: runs, dependencies: .init(
            hosts: LiveHostDirectory(hostService: hostService, mirrors: mirrors), preflight: FakePreflight(),
            snapshots: FakeSync(), bundles: FakeSync(), results: FakeResults(), config: FakeConfig(),
            worktrees: FakeWorktrees(), sessionTitle: { _ in nil }, directory: mirrors))

        var frames: [ServerFrame] = []
        service.handle(.logs(run: id, follow: false, from: nil), caller: .human, cid: 7) { frames.append($0) }
        try await waitUntil { frames.count == 2 }
        XCTAssertEqual(frames, [.delegateOutput(cid: 7, stream: "stdout", offset: 0, data: Data("built ok\n".utf8)),
                                .ack(cid: 7)])
        XCTAssertTrue(dialer.connections.allSatisfy { $0.requestIDs.isEmpty }, "the host was not asked")
        hostService.forget(slot: host.slot)
    }
}
