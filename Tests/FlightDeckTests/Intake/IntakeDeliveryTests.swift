import XCTest
import IntakeKit
@testable import FlightDeck

/// Records every argv it's called with and answers by matching "<exe> <first arg>" against
/// `responses`, defaulting to a clean success — enough to drive `IntakeDelivery` through a
/// realistic `am macros start-session` → `am mail send` / `br update` / `am file_reservations
/// release` sequence without a real process.
private final class FakeRunner: FlywheelProcessRunner, @unchecked Sendable {
    private(set) var argv: [[String]] = []
    var responses: [String: (stdout: String, exitCode: Int32)] = [
        "am macros": (#"{"agent":{"name":"FDName"},"inbox":[]}"#, 0),
    ]
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        argv.append([exe] + args)
        let key = ([exe] + args.prefix(1)).joined(separator: " ")
        return responses[key] ?? ("", 0)
    }
}

final class IntakeDeliveryTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeDeliveryTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeDelivery(runner: FakeRunner, inject: @escaping (String, String, UUID) -> Bool = { _, _, _ in true }) -> IntakeDelivery {
        IntakeDelivery(runner: runner, amPath: "am", brPath: "br", store: IntakeStore(root: root), inject: inject)
    }

    func testDeliverSendsMailWithArgvFromABootedIdentity() async {
        let runner = FakeRunner()
        let delivery = makeDelivery(runner: runner)
        let intakeID = UUID()

        let warnings = await delivery.deliver(
            [.mail(to: "BlueFalcon", bead: "b1", subject: "subj", body: "body", urgent: false)],
            project: "/tmp/proj", intakeID: intakeID)

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(runner.argv, [
            ["am", "macros", "start-session", "--project", "/tmp/proj", "--program", "flightdeck", "--model", "n/a", "--json"],
            ["am", "mail", "send", "--project", "/tmp/proj", "--from", "FDName", "--to", "BlueFalcon",
             "--subject", "subj", "--body", "body", "--thread-id", "bead:b1", "--topic", "fd-intake"],
        ])
    }

    func testUrgentMailAddsImportanceAndAckRequired() async {
        let runner = FakeRunner()
        let delivery = makeDelivery(runner: runner)

        _ = await delivery.deliver(
            [.mail(to: "BlueFalcon", bead: "b1", subject: "s", body: "b", urgent: true)],
            project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(runner.argv.last, [
            "am", "mail", "send", "--project", "/tmp/proj", "--from", "FDName", "--to", "BlueFalcon",
            "--subject", "s", "--body", "b", "--thread-id", "bead:b1", "--topic", "fd-intake",
            "--importance", "high", "--ack-required",
        ])
    }

    func testReclaimUpdatesBeadThenReleasesReservations() async {
        let runner = FakeRunner()
        let delivery = makeDelivery(runner: runner)
        let intakeID = UUID()

        let warnings = await delivery.deliver(
            [.reclaim(bead: "b1", agent: "BlueFalcon", reason: "why")], project: "/tmp/proj", intakeID: intakeID)

        // A reclaim needs no FD Agent-Mail identity, so no `am macros start-session` runs first.
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(runner.argv, [
            ["br", "update", "b1", "--status", "open", "--assignee", "", "--actor", "flightdeck-intake:\(intakeID.uuidString)"],
            ["am", "file_reservations", "release", "/tmp/proj", "BlueFalcon"],
        ])
    }

    func testReservationReleaseFailureIsAWarningNotAnAbort() async {
        let runner = FakeRunner()
        runner.responses["am file_reservations"] = ("cannot release another agent's reservations", 1)
        let delivery = makeDelivery(runner: runner)

        let warnings = await delivery.deliver(
            [.reclaim(bead: "b1", agent: "BlueFalcon", reason: "why")], project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("cannot release another agent's reservations"), warnings[0])
    }

    func testFailedReclaimSkipsReservationReleaseAndWarns() async {
        let runner = FakeRunner()
        runner.responses["br update"] = ("issue is locked", 1)
        let delivery = makeDelivery(runner: runner)

        let warnings = await delivery.deliver(
            [.reclaim(bead: "b1", agent: "BlueFalcon", reason: "why")], project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("issue is locked"), warnings[0])
        // Nothing to release if the bead was never actually reclaimed.
        XCTAssertFalse(runner.argv.contains { $0.first == "am" && $0.dropFirst().first == "file_reservations" })
    }

    func testBootFailureWarnsPerMailButStillRunsInjectAndReclaim() async {
        let runner = FakeRunner()
        runner.responses["am macros"] = ("no such project", 1)
        var injected = false
        let delivery = makeDelivery(runner: runner) { _, _, _ in injected = true; return true }
        let intakeID = UUID()

        let warnings = await delivery.deliver([
            .reclaim(bead: "b1", agent: "BlueFalcon", reason: "why"),
            .inject(agent: "BlueFalcon", bead: "b1", text: "stop"),
            .mail(to: "BlueFalcon", bead: "b1", subject: "s", body: "b", urgent: false),
        ], project: "/tmp/proj", intakeID: intakeID)

        XCTAssertTrue(injected, "inject must not depend on FD's Agent-Mail identity")
        XCTAssertTrue(runner.argv.contains { $0.first == "br" }, "reclaim must not depend on FD's Agent-Mail identity")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("BlueFalcon"), warnings[0])
    }

    func testInjectAfterAFailedReclaimGetsANeutralNoticeInstead() async {
        let runner = FakeRunner()
        runner.responses["br update"] = ("issue is locked", 1)
        var seenText: String?
        let delivery = makeDelivery(runner: runner) { _, text, _ in seenText = text; return true }

        _ = await delivery.deliver([
            .reclaim(bead: "b1", agent: "BlueFalcon", reason: "why"),
            .inject(agent: "BlueFalcon", bead: "b1", text: "Stop work on b1: why. It has been reclaimed and returned to open."),
        ], project: "/tmp/proj", intakeID: UUID())

        let text = try! XCTUnwrap(seenText)
        XCTAssertFalse(text.contains("has been reclaimed"), text)
        XCTAssertTrue(text.contains("could not reclaim"), text)
        XCTAssertTrue(text.hasPrefix("Stop work on b1"), text)
    }

    func testInjectAfterASuccessfulReclaimKeepsThePlannedText() async {
        let runner = FakeRunner()
        var seenText: String?
        let delivery = makeDelivery(runner: runner) { _, text, _ in seenText = text; return true }

        _ = await delivery.deliver([
            .reclaim(bead: "b1", agent: "BlueFalcon", reason: "why"),
            .inject(agent: "BlueFalcon", bead: "b1", text: "Stop work on b1: why. It has been reclaimed and returned to open."),
        ], project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(seenText, "Stop work on b1: why. It has been reclaimed and returned to open.")
    }

    func testFailedMailProducesAWarningQuotingFirstLine() async {
        let runner = FakeRunner()
        runner.responses["am mail"] = ("rejected: unknown recipient\nsecond line", 1)
        let delivery = makeDelivery(runner: runner)

        let warnings = await delivery.deliver(
            [.mail(to: "Nobody", bead: "b1", subject: "s", body: "b", urgent: false)],
            project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("rejected: unknown recipient"), warnings[0])
        XCTAssertFalse(warnings[0].contains("second line"), warnings[0])
    }

    func testInjectIsCalledWithTheDeterministicToken() async {
        let runner = FakeRunner()
        var seen: (String, String, UUID)?
        let delivery = makeDelivery(runner: runner) { agent, text, token in
            seen = (agent, text, token); return true
        }
        let intakeID = UUID()

        let warnings = await delivery.deliver(
            [.inject(agent: "BlueFalcon", bead: "b1", text: "hello")], project: "/tmp/proj", intakeID: intakeID)

        XCTAssertEqual(warnings, [])
        let (agent, text, token) = try! XCTUnwrap(seen)
        XCTAssertEqual(agent, "BlueFalcon")
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(token, IntakeDelivery.injectToken(intake: intakeID, bead: "b1"))
    }

    func testInjectReturningFalseIsAWarning() async {
        let runner = FakeRunner()
        let delivery = makeDelivery(runner: runner) { _, _, _ in false }

        let warnings = await delivery.deliver(
            [.inject(agent: "BlueFalcon", bead: "b1", text: "hello")], project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(warnings.count, 1)
    }

    func testIdentityIsCachedAcrossDeliverCalls() async {
        let runner = FakeRunner()
        let delivery = makeDelivery(runner: runner)

        _ = await delivery.deliver([.mail(to: "A", bead: "b1", subject: "s", body: "b", urgent: false)],
                                    project: "/tmp/proj", intakeID: UUID())
        _ = await delivery.deliver([.mail(to: "A", bead: "b2", subject: "s", body: "b", urgent: false)],
                                    project: "/tmp/proj", intakeID: UUID())

        let startSessionCalls = runner.argv.filter { $0.first == "am" && $0.dropFirst().first == "macros" }
        XCTAssertEqual(startSessionCalls.count, 1)

        let cache = try! JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("agent-mail-identities.json")))
        XCTAssertEqual(cache["/tmp/proj"], "FDName")
    }

    func testEmptyActionsSkipsBootEntirely() async {
        let runner = FakeRunner()
        let delivery = makeDelivery(runner: runner)

        let warnings = await delivery.deliver([], project: "/tmp/proj", intakeID: UUID())

        XCTAssertEqual(warnings, [])
        XCTAssertTrue(runner.argv.isEmpty)
    }

    func testInjectTokenIsStableAndDiffersPerBead() {
        let intake = UUID()
        let t1 = IntakeDelivery.injectToken(intake: intake, bead: "b1")
        let t2 = IntakeDelivery.injectToken(intake: intake, bead: "b1")
        let t3 = IntakeDelivery.injectToken(intake: intake, bead: "b2")
        XCTAssertEqual(t1, t2)
        XCTAssertNotEqual(t1, t3)
    }
}
