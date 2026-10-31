import FleetKit
import XCTest

/// `flightdeck infra budget` (`/budget`), over `FakeTransport` through the real `CLIRunner`.
final class InfraBudgetCommandTests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var code: Int32?

    private func runner(_ args: [String], transport: FakeTransport) -> CLIRunner {
        let r = CLIRunner(invocation: try! CLIArguments.parse(args), transport: transport,
                          context: CLIContext(selfID: nil, cwd: "/r", json: false, isTTY: true),
                          out: { self.out.append($0) }, err: { self.err.append($0) },
                          finish: { self.code = $0 }, schedule: { _, _ in })
        r.run()
        transport.push(.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial))
        return r
    }

    private func parsed(_ args: String...) throws -> InfraRequest.BudgetAction? {
        guard case .infra(.budget(let action)) = try CLIArguments.parse(["infra", "budget"] + args).command else { return nil }
        return action
    }

    func testParsesEveryForm() throws {
        XCTAssertEqual(try parsed(), .show)
        XCTAssertEqual(try parsed("show"), .show)
        XCTAssertEqual(try parsed("20"), .set(usd: 20))
        XCTAssertEqual(try parsed("$7.50"), .set(usd: 7.5))
        XCTAssertEqual(try parsed("set", "3"), .set(usd: 3))
        XCTAssertEqual(try parsed("renew"), .renew(usd: nil))
        XCTAssertEqual(try parsed("renew", "5"), .renew(usd: 5))
        XCTAssertEqual(try parsed("clear"), .clear)
        XCTAssertEqual(try parsed("off"), .clear)
    }

    func testRefusesABadAmountOrAnExtraWord() {
        for args in [["0"], ["-3"], ["lots"], ["set"], ["renew", "x"], ["20", "30"], ["nan"], ["inf"]] {
            XCTAssertThrowsError(try CLIArguments.parse(["infra", "budget"] + args), "\(args)")
        }
    }

    func testPrintsTheLineOrTheJSON() throws {
        let budget = WireSessionBudget(session: "S", capUsd: 5, since: nil, spentUsd: 1, remainingUsd: 4, hourlyUsd: 0,
                                       exhaustsIn: nil, machines: [], line: "session budget $5.00 · spent ~$1.00 · $4.00 left")
        let t = FakeTransport()
        _ = runner(["infra", "budget", "5"], transport: t)
        guard case .req(let cid, .infra(.budget(.set(5))))? = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.infraBudget(cid: cid, budget))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, [budget.line])

        out = []; code = nil
        let j = FakeTransport()
        _ = runner(["infra", "budget", "--json"], transport: j)
        guard case .req(let jcid, _)? = j.sent.last else { return XCTFail() }
        j.push(.infraBudget(cid: jcid, budget))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.joined().contains("\"capUsd\""), "\(out)")
    }

    func testARefusalExits125() throws {
        let t = FakeTransport()
        _ = runner(["infra", "budget"], transport: t)
        guard case .req(let cid, _)? = t.sent.last else { return XCTFail() }
        t.push(.err(cid: cid, code: "infra_no_session", message: "a cloud budget belongs to a Flight Deck session"))
        XCTAssertEqual(code, 125)
        XCTAssertEqual(err, ["flightdeck: a cloud budget belongs to a Flight Deck session"])
    }
}
