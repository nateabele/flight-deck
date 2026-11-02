import FleetKit
import XCTest
@testable import FlightDeck

/// What a paired phone may ask of the cloud service: list, extend and stop by name, nothing that
/// creates a machine or reaches an account. Over a real socket and the real `InfraService`
/// (faked cloud), so the streamed `infraProgress` frames and the terminal frame are seen as the
/// phone sees them.
@MainActor
final class PhoneInfraRequestTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var infra: InfraHarness!
    private var client: FleetClient?

    override func setUp() async throws {
        infra = try InfraHarness()
        harness = FleetTestHarness()
        harness.service.infra = infra.service
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness.service.stop()
        harness = nil
    }

    func testThePermissionTable() {
        let allowed: [InfraRequest] = [.list(orphans: false), .extend(name: "gpu", seconds: 600), .down(name: "gpu", orphanID: nil)]
        let refused: [InfraRequest] = [.up(name: "gpu", cwd: "/r"), .doctor, .list(orphans: true),
                                       .down(name: "", orphanID: "instance:i-0"), .budget(.show), .budget(.clear)]
        XCTAssertTrue(allowed.allSatisfy(FleetService.phoneMayRequest))
        XCTAssertFalse(refused.contains(where: FleetService.phoneMayRequest))
    }

    /// Frames for `request` from a paired phone, up to its terminal one.
    private func phone(_ request: InfraRequest) async throws -> [ServerFrame] {
        let port = try await harness.start()
        let client = FleetClient(key: harness.key)
        self.client = client
        let done = expectation(description: "terminal frame")
        var cid = -1
        var frames: [ServerFrame] = []
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(FleetRequest.infra(request)) }
            guard frame.correlationID == cid else { return }
            frames.append(frame)
            if !frame.continuesStream { done.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [done], timeout: 10)
        return frames
    }

    func testAPhoneListsMachines() async throws {
        try infra.registry.upsert(.fixture(name: "gpu"))
        let frames = try await phone(.list(orphans: false))
        guard case .infraList(_, let machines, _, _)? = frames.last, frames.count == 1 else { return XCTFail("\(frames)") }
        XCTAssertEqual(machines.map(\.name), ["gpu"])
    }

    func testAPhoneExtendsAMachine() async throws {
        try infra.registry.upsert(.fixture(name: "gpu", machineDeadline: InfraMachine.fixtureNow.addingTimeInterval(7200)))
        let frames = try await phone(.extend(name: "gpu", seconds: 600))
        guard case .infraMachine(_, let m)? = frames.last else { return XCTFail("\(frames)") }
        XCTAssertEqual(m.ttlRemaining, 4200)
    }

    func testAPhoneStopsAMachineAndSeesTheProgressFirst() async throws {
        try infra.registry.upsert(.fixture(name: "gpu"))
        try infra.prepareWorkdir("gpu")
        let frames = try await phone(.down(name: "gpu", orphanID: nil))
        XCTAssertEqual(frames.last?.correlationID, frames.first?.correlationID)
        guard case .infraDone? = frames.last else { return XCTFail("\(frames)") }
        XCTAssertTrue(frames.contains { if case .infraProgress(_, "gpu destroyed") = $0 { true } else { false } }, "\(frames)")
        XCTAssertNil(infra.registry.machine(named: "gpu"))
    }

    func testAPhoneCannotCreateOrReachAnAccount() async throws {
        for request in [InfraRequest.up(name: "gpu", cwd: "/r"), .doctor, .list(orphans: true),
                        .down(name: "", orphanID: "instance:i-0dead"), .budget(.clear)] {
            let frames = try await phone(request)
            guard case .err(_, "out_of_scope", _)? = frames.last, frames.count == 1 else { return XCTFail("\(request): \(frames)") }
            client?.disconnect()
        }
        XCTAssertTrue(infra.account.deleted.isEmpty)
        XCTAssertTrue(infra.registry.machines.isEmpty)
    }
}
