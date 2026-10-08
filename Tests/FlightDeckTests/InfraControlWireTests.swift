import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// `infra.*` on the control socket (Task 16): the CLI and the app are separate binaries a
/// release can skew, so every op and tag is pinned, every frame round-trips, and the app's
/// answers are driven through `InfraService` over the faked cloud (`InfraHarness`).
@MainActor
final class InfraControlWireTests: XCTestCase {
    private let machine = WireInfraMachine(
        name: "gpu", cloud: "aws", instanceType: "t3.small", region: "us-east-1", state: "ready", network: "public",
        hourlyUsd: 0.02, spentUsd: 0.01, ttlRemaining: 3000, monthUsd: 1, monthCapUsd: 50, failure: nil, costLine: "x")

    private func sorted<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    // MARK: Requests

    func testRequestsRoundTripWithPinnedOps() throws {
        let cases: [(FleetRequest, String)] = [
            (.infra(.up(name: "gpu", cwd: "/r")), "infra.up"), (.infra(.down(name: "gpu", orphanID: nil)), "infra.down"),
            (.infra(.down(name: "", orphanID: "instance:i-0dead")), "infra.down"),
            (.infra(.list(orphans: true)), "infra.ls"), (.infra(.list(orphans: false)), "infra.ls"),
            (.infra(.doctor), "infra.doctor"), (.infra(.extend(name: "gpu", seconds: 600)), "infra.extend")]
        for (r, op) in cases {
            let data = try JSONEncoder().encode(r)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(op)\""), "\(r)")
            XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), r)
            let framed = try JSONEncoder().encode(ClientFrame.req(cid: 2, r))
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: framed), .req(cid: 2, r))
        }
    }

    func testRequestShapesArePinned() throws {
        XCTAssertEqual(try sorted(FleetRequest.infra(.up(name: "gpu", cwd: "/w/app"))),
                       #"{"cwd":"/w/app","name":"gpu","op":"infra.up"}"#)
        XCTAssertEqual(try sorted(FleetRequest.infra(.down(name: "gpu", orphanID: nil))), #"{"name":"gpu","op":"infra.down"}"#)
        XCTAssertEqual(try sorted(FleetRequest.infra(.down(name: "", orphanID: "firewall:fd-gpu"))),
                       #"{"name":"","op":"infra.down","orphanID":"firewall:fd-gpu"}"#)
        XCTAssertEqual(try sorted(FleetRequest.infra(.list(orphans: true))), #"{"op":"infra.ls","orphans":true}"#)
        XCTAssertEqual(try sorted(FleetRequest.infra(.doctor)), #"{"op":"infra.doctor"}"#)
        XCTAssertEqual(try sorted(FleetRequest.infra(.extend(name: "gpu", seconds: 3600))),
                       #"{"name":"gpu","op":"infra.extend","seconds":3600}"#)
    }

    /// An `infra.*` op this build does not know must throw, never fall through to delegation
    /// as some other request.
    func testUnknownInfraOpThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(FleetRequest.self, from: Data(#"{"op":"infra.nuke"}"#.utf8)))
    }

    // MARK: Frames

    func testFramesRoundTrip() throws {
        let frames: [ServerFrame] = [
            .infraProgress(cid: 1, line: "creating aws_instance.this"), .infraMachine(cid: 1, machine),
            .infraList(cid: 2, [machine], orphans: ["instance:i-0dead"]),
            .infraList(cid: 2, [], orphans: [], unreadable: ["gcp": "gcloud: not signed in"]),
            .infraDoctor(cid: 3, [.init(name: "tofu", ok: true, detail: "1.8.3 (PATH)", fix: nil),
                                  .init(name: "account aws", ok: false, detail: "aws: signed out", fix: "aws sso login")]),
            .infraDone(cid: 4)]
        for f in frames {
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(f)), f)
            XCTAssertNotNil(f.correlationID, "\(f)")
        }
    }

    /// Ruling 1: the orphan list carries kind-qualified ids and the clouds it could not read,
    /// so "no orphans" is only ever said when every account was scanned.
    func testListShapeIsPinned() throws {
        XCTAssertEqual(try sorted(ServerFrame.infraList(cid: 2, [], orphans: ["security-group:sg-1"],
                                                         unreadable: ["gcp": "denied"])),
                       #"{"cid":2,"machines":[],"orphans":["security-group:sg-1"],"t":"infraList","unreadable":{"gcp":"denied"}}"#)
        // A frame written without `unreadable` still reads, as every account scanned.
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: Data(#"{"cid":2,"machines":[],"orphans":[],"t":"infraList"}"#.utf8)),
                       .infraList(cid: 2, [], orphans: []))
    }

    func testMachineJSONCarriesTheSpecFields() throws {
        let json = try sorted(ServerFrame.infraMachine(cid: 1, machine))
        for key in ["hourlyUsd", "spentUsd", "ttlRemaining", "monthUsd", "monthCapUsd", "costLine"] {
            XCTAssertTrue(json.contains("\"\(key)\""), key)
        }
        XCTAssertTrue(json.contains(#""t":"infraMachine""#), json)
    }

    func testOnlyProgressContinuesTheStream() {
        XCTAssertTrue(ServerFrame.infraProgress(cid: 1, line: "").continuesStream)
        for f: ServerFrame in [.infraDone(cid: 1), .infraMachine(cid: 1, machine), .infraList(cid: 1, [], orphans: []),
                               .infraDoctor(cid: 1, [])] {
            XCTAssertFalse(f.continuesStream, "\(f)")
        }
    }

    // MARK: Scope

    private let me = UUID()

    func testReadOnlySet() {
        XCTAssertTrue(InfraRequest.list(orphans: true).isReadOnly)
        XCTAssertTrue(InfraRequest.doctor.isReadOnly)
        for r: InfraRequest in [.up(name: "g", cwd: "/"), .down(name: "g", orphanID: nil), .extend(name: "g", seconds: 1)] {
            XCTAssertFalse(r.isReadOnly, "\(r)")
        }
    }

    /// `ls` and `doctor` read, so every level allows them; `up`, `down` and `extend` create,
    /// destroy or spend on a machine no one tab owns, so they follow the fleet-wide rule like
    /// `host prune`: `.full`, or a human shell.
    func testInfraScope() {
        for r: InfraRequest in [.list(orphans: true), .doctor] {
            for level in ControlScopeLevel.allCases {
                for caller in [ControlCaller.human, .session(me), .invalid] {
                    XCTAssertTrue(ControlScope.permits(.infra(r), level: level, caller: caller), "\(level) \(caller) \(r)")
                }
            }
        }
        for r: InfraRequest in [.up(name: "g", cwd: "/"), .down(name: "g", orphanID: nil), .extend(name: "g", seconds: 1)] {
            for level in ControlScopeLevel.allCases {
                XCTAssertTrue(ControlScope.permits(.infra(r), level: level, caller: .human), "\(level) \(r)")
                XCTAssertEqual(ControlScope.permits(.infra(r), level: level, caller: .session(me)), level == .full, "\(level) \(r)")
            }
            XCTAssertFalse(ControlScope.permits(.infra(r), level: .ownSession, caller: .invalid))
            XCTAssertFalse(ControlScope.permits(.infra(r), level: .readOnly, caller: .invalid))
        }
    }

    // MARK: Service routing

    /// Ruling 3: until the app builds `InfraService` (Task 18), every `infra.*` is refused by
    /// name rather than left waiting.
    func testFleetServiceWithoutInfraAnswersUnavailable() async throws {
        let harness = try FleetServiceHarness(hosts: [])
        try await harness.start()
        defer { harness.stop() }
        for request in [InfraRequest.doctor, .list(orphans: false), .up(name: "gpu", cwd: "/")] {
            let reply = try await harness.request(.infra(request))
            guard case .err(_, let code, let message) = reply else { return XCTFail("\(request): \(reply)") }
            XCTAssertEqual(code, "infra_unavailable")
            XCTAssertNotNil(message)
        }
    }

    // MARK: InfraService.handle

    private var h: InfraHarness!
    private var config: FakeConfig!
    override func setUp() async throws {
        h = try InfraHarness()
        config = FakeConfig()
    }
    override func tearDown() async throws { h = nil; config = nil }

    private let gpu = InfraConfig(source: .preset("aws-linux"), region: "us-east-1", instanceType: "t3.small", arch: nil, diskGB: nil,
                                  spot: false, ttl: .init(seconds: 3600), idle: .init(seconds: 1800), autoUp: false, vars: [:], maxHourly: nil)

    /// Every frame the request draws, up to and including the one that ends it.
    private func frames(_ request: InfraRequest, file: StaticString = #filePath, line: UInt = #line) async -> [ServerFrame] {
        var frames: [ServerFrame] = []
        let done = XCTestExpectation(description: "terminal frame")
        h.service.handle(request, cid: 7, config: config, worktrees: FakeWorktrees(root: h.repo)) { frame in
            XCTAssertEqual(frame.correlationID, 7, file: file, line: line)
            frames.append(frame)
            if !frame.continuesStream { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 10)
        return frames
    }

    private func error(_ frames: [ServerFrame], file: StaticString = #filePath, line: UInt = #line) -> (code: String, message: String)? {
        guard case .err(_, let code, let message)? = frames.last else {
            XCTFail("expected an err, got \(frames)", file: file, line: line)
            return nil
        }
        return (code, message ?? "")
    }

    func testUpReadsTheRecipeFromCwdsRepoStreamsProgressAndEndsWithTheMachine() async throws {
        config.config = DelegateConfig(infra: ["gpu": gpu])
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let frames = await frames(.up(name: "gpu", cwd: h.repo.appendingPathComponent("sub").path))
        guard case .infraMachine(_, let m)? = frames.last else { return XCTFail("\(frames)") }
        XCTAssertEqual(m.name, "gpu"); XCTAssertEqual(m.state, "ready"); XCTAssertEqual(m.cloud, "aws")
        XCTAssertEqual(m.network, "public"); XCTAssertEqual(m.hourlyUsd, 0.5); XCTAssertEqual(m.ttlRemaining, 3600)
        XCTAssertEqual(m.monthCapUsd, 50)
        XCTAssertTrue(m.costLine.hasPrefix("gpu · t3.small · $0.50/h est."), m.costLine)
        XCTAssertEqual(h.registry.machine(named: "gpu")?.repoRoot, h.repo.standardizedFileURL.path)
        let lines = frames.dropLast().compactMap { f -> String? in if case .infraProgress(_, let l) = f { return l }; return nil }
        XCTAssertEqual(lines.count, frames.count - 1, "everything before the machine is progress: \(frames)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("cost: gpu · t3.small") }, "\(lines)")
    }

    func testUpWithoutTheRecipeIsNotFound() async throws {
        config.config = DelegateConfig(infra: ["other": gpu])
        let frames = await frames(.up(name: "gpu", cwd: h.repo.path))
        guard let (code, message) = error(frames) else { return }
        XCTAssertEqual(code, "infra_not_found")
        XCTAssertTrue(message.contains("[infra.gpu]"), message)
        XCTAssertEqual(h.tofu.calls, [])
    }

    func testPreflightRefusalListsEachFailingCheckWithItsFix() async throws {
        config.config = DelegateConfig(infra: ["gpu": gpu])
        h.budget.allowedTypes["aws"] = []
        let frames = await frames(.up(name: "gpu", cwd: h.repo.path))
        guard let (code, message) = error(frames) else { return }
        XCTAssertEqual(code, "infra_preflight")
        let lines = message.split(separator: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("budget: ") && $0.contains("Settings → Cloud") }, message)
        XCTAssertFalse(lines.contains { $0.hasPrefix("config: ") }, "passing checks are not listed: \(message)")
        XCTAssertEqual(h.tofu.calls, [])
    }

    func testNameInUseAndRefusedAndNotFoundKeepTheirCodes() async throws {
        config.config = DelegateConfig(infra: ["gpu": gpu])
        try h.hosts.enroll(key: .mint(), name: "gpu", endpoints: [])
        var frames = await self.frames(.up(name: "gpu", cwd: h.repo.path))
        XCTAssertEqual(error(frames)?.code, "infra_name_in_use")

        try h.registry.upsert(.fixture(name: "db", state: .failed))
        frames = await self.frames(.extend(name: "db", seconds: 600))
        XCTAssertEqual(error(frames)?.code, "infra_refused")
        XCTAssertTrue(error(frames)?.message.contains("only a running machine") == true)

        frames = await self.frames(.down(name: "nope", orphanID: nil))
        XCTAssertEqual(error(frames)?.code, "infra_not_found")
        frames = await self.frames(.down(name: "", orphanID: "instance:i-0none"))
        XCTAssertEqual(error(frames)?.code, "infra_not_found")
    }

    func testFailedApplyIsInfraFailedWithTheRecordedText() async throws {
        config.config = DelegateConfig(infra: ["gpu": gpu])
        h.tofu.failApply = TofuError.failed(step: "apply", message: "InsufficientInstanceCapacity")
        let frames = await frames(.up(name: "gpu", cwd: h.repo.path))
        guard let (code, message) = error(frames) else { return }
        XCTAssertEqual(code, "infra_failed")
        XCTAssertEqual(message, h.registry.machine(named: "gpu")?.failure)
    }

    func testDownStreamsAndEndsDone() async throws {
        try h.registry.upsert(.fixture(name: "gpu"))
        try h.prepareWorkdir("gpu")
        let frames = await frames(.down(name: "gpu", orphanID: nil))
        XCTAssertEqual(frames.last, .infraDone(cid: 7))
        XCTAssertTrue(frames.contains(.infraProgress(cid: 7, line: "gpu destroyed")), "\(frames)")
        XCTAssertNil(h.registry.machine(named: "gpu"))
    }

    func testDownOrphanDeletesIt() async throws {
        let orphan = OwnedResource(cloud: "aws", kind: .instance, id: "i-0dead", region: "us-east-1", name: "old")
        h.account.owned = [orphan]
        let frames = await frames(.down(name: "", orphanID: "instance:i-0dead"))
        XCTAssertEqual(frames, [.infraDone(cid: 7)])
        XCTAssertEqual(h.account.deleted, [orphan])
    }

    func testExtendAnswersTheMovedMachine() async throws {
        try h.registry.upsert(.fixture(name: "gpu", machineDeadline: InfraMachine.fixtureNow.addingTimeInterval(7200)))
        let frames = await frames(.extend(name: "gpu", seconds: 600))
        guard case .infraMachine(_, let m)? = frames.last, frames.count == 1 else { return XCTFail("\(frames)") }
        XCTAssertEqual(m.ttlRemaining, 4200)
    }

    func testListWithOrphansCarriesRefsAndUnreadableClouds() async throws {
        try h.registry.upsert(.fixture(name: "gpu"))
        h.account.owned = [OwnedResource(cloud: "aws", kind: .securityGroup, id: "sg-1", region: "us-east-1", name: "old")]
        h.gcpAccount.listError = URLError(.notConnectedToInternet)
        let frames = await frames(.list(orphans: true))
        guard case .infraList(_, let machines, let orphans, let unreadable)? = frames.last, frames.count == 1 else {
            return XCTFail("\(frames)")
        }
        XCTAssertEqual(machines.map(\.name), ["gpu"])
        XCTAssertEqual(orphans, ["security-group:sg-1"])
        XCTAssertEqual(Array(unreadable.keys), ["gcp"])

        let plain = await self.frames(.list(orphans: false))
        XCTAssertEqual(plain.count, 1)
        guard case .infraList(_, _, let none, let unscanned)? = plain.last else { return XCTFail("\(plain)") }
        XCTAssertEqual(none, []); XCTAssertEqual(unscanned, [:])
        XCTAssertEqual(h.account.owners.count, 1, "ls without --orphans scans no account")
    }

    func testDoctorAnswersItsChecks() async throws {
        let frames = await frames(.doctor)
        guard case .infraDoctor(_, let checks)? = frames.last, frames.count == 1 else { return XCTFail("\(frames)") }
        XCTAssertEqual(checks.first?.name, "tools")
        XCTAssertTrue(checks.contains { $0.name == "account aws" })
    }
}
