import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A commander the test answers by hand, so a request can be held mid-stream.
@MainActor
private final class FakeInfra: InfraCommanding {
    var requests: [InfraRequest] = []
    var script: (@MainActor (@escaping (String) -> Void) async -> Result<InfraOutcome, InfraRequestError>)?

    func infra(_ request: InfraRequest, progress: @escaping (String) -> Void) async -> Result<InfraOutcome, InfraRequestError> {
        requests.append(request)
        return await script?(progress) ?? .success(.done)
    }
}

@MainActor
final class SessionCloudModelTests: XCTestCase {
    func testDestroyStreamsProgressThenClearsOnTheTerminalFrame() async {
        let fake = FakeInfra()
        let model = SessionCloudModel(commander: fake)
        var midway: SessionCloudModel.Activity?
        fake.script = { progress in
            progress("destroying instance")
            progress("removing firewall")
            midway = model.activity["gpu"]
            return .success(.done)
        }
        await model.destroy("gpu")
        XCTAssertEqual(fake.requests, [.down(name: "gpu", orphanID: nil)])
        XCTAssertEqual(midway, .init(action: .destroy, lines: ["destroying instance", "removing firewall"]))
        XCTAssertTrue(midway?.running ?? false)
        XCTAssertNil(model.activity["gpu"], "a finished destroy leaves nothing behind; the machine leaves the cloud instead")
    }

    func testExtendSendsOneHour() async {
        let fake = FakeInfra()
        await SessionCloudModel(commander: fake).extend("gpu")
        XCTAssertEqual(fake.requests, [.extend(name: "gpu", seconds: 3600)])
    }

    func testARefusalStaysInlineWithTheMacsSentenceUntilDismissed() async {
        let fake = FakeInfra()
        let model = SessionCloudModel(commander: fake)
        fake.script = { _ in .failure(.server(code: "infra_refused", message: "past the machine's timer")) }
        await model.extend("gpu")
        XCTAssertEqual(model.activity["gpu"]?.failure, "past the machine's timer")
        XCTAssertFalse(model.isBusy("gpu"))
        model.dismissFailure("gpu")
        XCTAssertNil(model.activity["gpu"])
    }

    func testAnOlderMacIsToldToUpdate() async {
        let fake = FakeInfra()
        let model = SessionCloudModel(commander: fake)
        fake.script = { _ in .failure(.server(code: "out_of_scope", message: nil)) }
        await model.destroy("gpu")
        XCTAssertEqual(model.activity["gpu"]?.failure,
                       "Update Flight Deck on your Mac to control cloud machines from the phone.")
    }

    func testASecondRequestOnABusyMachineIsDropped() async {
        let fake = FakeInfra()
        let model = SessionCloudModel(commander: fake)
        var release: CheckedContinuation<Void, Never>?
        fake.script = { _ in
            await withCheckedContinuation { release = $0 }
            return .success(.done)
        }
        let first = Task { await model.extend("gpu") }
        while release == nil { await Task.yield() }
        XCTAssertTrue(model.isBusy("gpu"))
        await model.extend("gpu")
        XCTAssertEqual(fake.requests.count, 1, "a second tap must not stack another hour")
        release?.resume()
        await first.value
        XCTAssertFalse(model.isBusy("gpu"))
    }

    func testADisconnectIsShownAsFailureNotAsSuccess() async {
        let fake = FakeInfra()
        let model = SessionCloudModel(commander: fake)
        fake.script = { _ in .failure(.disconnected) }
        await model.destroy("gpu")
        XCTAssertNotNil(model.activity["gpu"]?.failure)
    }
}
