import FleetKit
import XCTest

extension WireInfraMachine {
    static func fixture(name: String = "gpu", instanceType: String = "t3.small", state: String = "ready",
                        hourlyUsd: Double? = 0.02, spentUsd: Double = 0, ttlRemaining: Int = 3600,
                        costLine: String = "gpu · t3.small · $0.02/h est. · up 0m · ~$0.00 · TTL 1h · month ~$1.00 of $50") -> WireInfraMachine {
        WireInfraMachine(name: name, cloud: "aws", instanceType: instanceType, region: "us-east-1", state: state,
                         network: "tailnet", hourlyUsd: hourlyUsd, spentUsd: spentUsd, ttlRemaining: ttlRemaining,
                         monthUsd: 1, monthCapUsd: 50, failure: nil, costLine: costLine)
    }
}

/// `flightdeck infra …`, driven frame by frame over `FakeTransport` through the real
/// `CLIRunner`: what each verb sends, prints, and exits with.
final class InfraCommandsTests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var code: Int32?
    private var stdout: String { out.joined(separator: "\n") }
    private var stderr: String { err.joined(separator: "\n") }

    private func runner(_ args: String..., transport: FakeTransport, isTTY: Bool = true) -> CLIRunner {
        let invocation = (try? CLIArguments.parse(args)) ?? CLIInvocation(command: .help)
        let r = CLIRunner(invocation: invocation, transport: transport,
                          context: CLIContext(selfID: nil, cwd: "/r", json: false, isTTY: isTTY),
                          out: { self.out.append($0) }, err: { self.err.append($0) },
                          finish: { self.code = $0 }, schedule: { _, _ in })
        r.run()
        transport.push(.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial))
        return r
    }

    private func sent(_ t: FakeTransport) -> (cid: Int, request: InfraRequest)? {
        guard case .req(let cid, .infra(let request))? = t.sent.last else { XCTFail("\(t.sent)"); return nil }
        return (cid, request)
    }

    func testUpPrintsProgressToStderrAndCostLine() throws {
        let t = FakeTransport()
        _ = runner("infra", "up", "gpu", transport: t)
        let (cid, request) = try XCTUnwrap(sent(t))
        XCTAssertEqual(request, .up(name: "gpu", cwd: "/r"))
        let machine = WireInfraMachine.fixture()
        t.push(.infraProgress(cid: cid, line: "create aws_instance.this"))
        t.push(.infraProgress(cid: cid, line: "cost: \(machine.costLine)"))
        XCTAssertNil(code, "progress continues the stream")
        t.push(.infraMachine(cid: cid, machine))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(err, ["flightdeck: create aws_instance.this", "flightdeck: \(machine.costLine)"],
                       "the cost line once, though both the progress and the machine carry it")
        XCTAssertTrue(stdout.contains("gpu") && stdout.contains("t3.small"), stdout)
    }

    func testUpWithJSONPrintsTheMachine() throws {
        let t = FakeTransport()
        _ = runner("infra", "up", "gpu", "--json", transport: t)
        let (cid, _) = try XCTUnwrap(sent(t))
        t.push(.infraMachine(cid: cid, .fixture()))
        XCTAssertEqual(code, 0)
        let decoded = try JSONDecoder().decode(WireInfraMachine.self, from: Data(stdout.utf8))
        XCTAssertEqual(decoded, .fixture())
        XCTAssertTrue(stderr.contains("gpu · t3.small"), "the cost line still goes to stderr")
    }

    func testPreflightErrorExitsWithItsOwnCodeAndOneLinePerCheck() throws {
        let t = FakeTransport()
        _ = runner("infra", "up", "gpu", transport: t)
        let (cid, _) = try XCTUnwrap(sent(t))
        t.push(.err(cid: cid, code: "infra_preflight",
                    message: "budget: g6.xlarge is not allowed — Settings → Cloud → Budget\naccount aws: signed out — aws sso login"))
        XCTAssertEqual(code, 125)
        XCTAssertEqual(err, ["flightdeck: budget: g6.xlarge is not allowed — Settings → Cloud → Budget",
                             "flightdeck: account aws: signed out — aws sso login"])
    }

    func testEveryInfraRefusalIs125AndAnythingElseIs1() throws {
        for (refusal, expected): (String, Int32) in [("infra_name_in_use", 125), ("infra_enroll_timeout", 125),
                                                      ("infra_not_found", 125), ("infra_failed", 125),
                                                      ("infra_unavailable", 125), ("infra_refused", 125),
                                                      ("out_of_scope", 1)] {
            let t = FakeTransport()
            code = nil
            _ = runner("infra", "extend", "gpu", "1h", transport: t)
            let (cid, request) = try XCTUnwrap(sent(t))
            XCTAssertEqual(request, .extend(name: "gpu", seconds: 3600))
            t.push(.err(cid: cid, code: refusal, message: "no"))
            XCTAssertEqual(code, expected, refusal)
        }
    }

    func testLsTableHasTotalRow() throws {
        let t = FakeTransport()
        _ = runner("infra", "ls", transport: t)
        let (cid, request) = try XCTUnwrap(sent(t))
        XCTAssertEqual(request, .list(orphans: false))
        t.push(.infraList(cid: cid, [.fixture(name: "a", spentUsd: 1.5), .fixture(name: "b", spentUsd: 0.5)], orphans: []))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout.split(separator: "\n").first?.split(separator: " "),
                       ["NAME", "CLOUD", "TYPE", "STATE", "NET", "$/H", "SPENT", "TTL"], stdout)
        let total = try XCTUnwrap(out.last?.split(separator: "\n").last)
        XCTAssertTrue(total.hasPrefix("TOTAL"), stdout)
        XCTAssertTrue(total.contains("$0.04") && total.contains("~$2.00"), String(total))
        XCTAssertFalse(stdout.contains("orphans"), "no orphan section unless asked")
    }

    /// Ruling 1: an account that could not be scanned is named with why, and "none" is never
    /// said while one was unreadable.
    func testLsOrphansNamesUnreadableCloudsAndNeverSaysNoneThen() throws {
        var t = FakeTransport()
        _ = runner("infra", "ls", "--orphans", transport: t)
        var (cid, request) = try XCTUnwrap(sent(t))
        XCTAssertEqual(request, .list(orphans: true))
        t.push(.infraList(cid: cid, [], orphans: [], unreadable: ["gcp": "gcloud: not signed in"]))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains("could not scan gcp: gcloud: not signed in"), stdout)
        XCTAssertFalse(stdout.contains("none"), stdout)

        out = []
        t = FakeTransport()
        _ = runner("infra", "ls", "--orphans", transport: t)
        (cid, _) = try XCTUnwrap(sent(t))
        t.push(.infraList(cid: cid, [.fixture()], orphans: ["instance:i-0dead"], unreadable: ["aws": "expired token"]))
        XCTAssertTrue(stdout.contains("  instance:i-0dead"), stdout)
        XCTAssertTrue(stdout.contains("could not scan aws: expired token"), stdout)

        out = []
        t = FakeTransport()
        _ = runner("infra", "ls", "--orphans", transport: t)
        (cid, _) = try XCTUnwrap(sent(t))
        t.push(.infraList(cid: cid, [], orphans: [], unreadable: [:]))
        XCTAssertTrue(stdout.contains("orphans: none"), stdout)
    }

    func testDownByNameAndByOrphan() throws {
        var t = FakeTransport()
        _ = runner("infra", "down", "gpu", transport: t)
        var (cid, request) = try XCTUnwrap(sent(t))
        XCTAssertEqual(request, .down(name: "gpu", orphanID: nil))
        t.push(.infraProgress(cid: cid, line: "gpu destroyed"))
        t.push(.infraDone(cid: cid))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(err, ["flightdeck: gpu destroyed"])

        t = FakeTransport()
        _ = runner("infra", "down", "--orphan", "instance:i-0dead", transport: t)
        (cid, request) = try XCTUnwrap(sent(t))
        XCTAssertEqual(request, .down(name: "", orphanID: "instance:i-0dead"))
    }

    func testDoctorPrintsEachCheckAndItsFix() throws {
        let t = FakeTransport()
        _ = runner("infra", "doctor", transport: t)
        let (cid, request) = try XCTUnwrap(sent(t))
        XCTAssertEqual(request, .doctor)
        t.push(.infraDoctor(cid: cid, [.init(name: "tools", ok: true, detail: "tofu 1.8.3", fix: nil),
                                       .init(name: "account aws", ok: false, detail: "signed out", fix: "aws sso login")]))
        XCTAssertEqual(out, ["✓ tools — tofu 1.8.3\n✗ account aws — signed out\n  fix: aws sso login"])
        XCTAssertEqual(code, 1, "a failing check is a non-zero exit, as recipe check's is")
    }

    /// Ctrl-C during `up` leaves the app creating it, and says how to cancel.
    func testInterruptDuringUpSaysStillCreatingAndExits130() throws {
        let t = FakeTransport()
        let r = runner("infra", "up", "gpu", transport: t)
        let (cid, _) = try XCTUnwrap(sent(t))
        t.push(.infraProgress(cid: cid, line: "tofu init"))
        let sentBefore = t.sent.count
        r.interrupt()
        XCTAssertEqual(code, 130)
        XCTAssertEqual(err.last, "flightdeck: still creating gpu in Flight Deck; `flightdeck infra down gpu` to cancel")
        XCTAssertEqual(t.sent.count, sentBefore, "nothing is cancelled: the app finishes the machine")
    }
}
