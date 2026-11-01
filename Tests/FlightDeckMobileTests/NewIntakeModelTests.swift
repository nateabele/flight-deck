import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
private final class NoFetcher: IntakeFetching {
    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void) {
        then(.failure(.server(code: "unknown_intake")))
    }
    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {}
}

/// Records what is sent and answers on demand, or before `sendIntake` returns.
@MainActor
private final class Commander: IntakeCommanding {
    private(set) var commands: [FleetCommand] = []
    private var pending: [(Result<Void, FleetRequestError>) -> Void] = []
    var answerBeforeReturning: Result<Void, FleetRequestError>?

    func sendIntake(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {
        commands.append(command)
        if let answer = answerBeforeReturning { return completion(answer) }
        pending.append(completion)
    }
    func answer(_ result: Result<Void, FleetRequestError>) { pending.removeFirst()(result) }

    var created: [(id: UUID, token: UUID, project: UUID, intent: String)] {
        commands.compactMap {
            if case .intakeCreate(let id, let token, let project, let intent) = $0 { return (id, token, project, intent) }
            return nil
        }
    }
}

/// Triage closes the sheet onto the new intake's screen before the Mac has answered, and a
/// refusal takes that screen back and reopens the sheet with the draft (spec §4.10).
@MainActor
final class NewIntakeModelTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private var commander: Commander!
    /// The models hold their fetcher `weak`, so the test keeps it alive.
    private var fetcher: NoFetcher!
    private var flightControl: FlightControlModel!
    private var drafts: DraftStore!
    private var model: NewIntakeModel!
    /// The navigation stack, as the ids pushed and not yet taken back.
    private var stack: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("intake-drafts-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        commander = Commander()
        fetcher = NoFetcher()
        flightControl = FlightControlModel(fetcher: fetcher, commander: commander)
        drafts = DraftStore(directory: dir)
        model = NewIntakeModel(
            flightControl: flightControl, drafts: drafts,
            open: { [unowned self] id in stack.append(id); return stack.count - 1 },
            close: { [unowned self] depth in stack.removeLast(stack.count - depth) })
    }

    func testOnlyAProjectWithFlightControlAndTheMacsLicenceOffersIt() {
        func project(intakes: [WireIntakeSummary]?, can: Bool?) -> WireProject {
            WireProject(id: a, name: "p", path: "/p", intakes: intakes, canCreateIntake: can)
        }
        XCTAssertTrue(NewIntakeModel.offers(project(intakes: [], can: true)))
        XCTAssertFalse(NewIntakeModel.offers(project(intakes: nil, can: true)), "Flight Control off")
        XCTAssertFalse(NewIntakeModel.offers(project(intakes: [], can: nil)), "an older Mac drops the socket on the op")
        XCTAssertFalse(NewIntakeModel.offers(project(intakes: [], can: false)))
    }

    func testTriageNeedsNonBlankText() {
        model.present(project: a)
        XCTAssertFalse(model.canTriage)
        model.text = " \n "
        XCTAssertFalse(model.canTriage)
        model.text = "Add dark mode"
        XCTAssertTrue(model.canTriage)
    }

    func testDraftsAreKeptPerProjectAcrossLeavingAndRelaunching() {
        model.present(project: a)
        model.text = "for a"
        model.select(b)
        XCTAssertEqual(model.text, "", "b has no draft")
        model.text = "for b"
        model.select(a)
        XCTAssertEqual(model.text, "for a")
        model.isPresented = false
        drafts.flush()
        XCTAssertEqual(drafts.draft(for: a), "for a")
        XCTAssertEqual(drafts.draft(for: b), "for b")
    }

    func testTriageSendsUnderAFreshIdOpensItsScreenAndClosesTheSheet() throws {
        model.present(project: a)
        model.text = "Add dark mode"
        model.triage()
        let sent = try XCTUnwrap(commander.created.first)
        XCTAssertEqual(sent.project, a)
        XCTAssertEqual(sent.intent, "Add dark mode")
        XCTAssertEqual(stack, [sent.id], "the intake's screen is open before the Mac has answered")
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(flightControl.detailModel(for: sent.id).awaitingCreation)
        XCTAssertEqual(model.text, "Add dark mode", "the draft stays until the Mac accepts")
    }

    func testAnAckClearsTheDraftAndStopsWaiting() throws {
        model.present(project: a)
        model.text = "Add dark mode"
        model.triage()
        let id = try XCTUnwrap(commander.created.first).id
        commander.answer(.success(()))
        XCTAssertFalse(flightControl.detailModel(for: id).awaitingCreation)
        XCTAssertEqual(model.text, "")
        drafts.flush()
        XCTAssertNil(drafts.draft(for: a))
        XCTAssertEqual(stack, [id], "the screen stays")
    }

    func testARefusalTakesTheScreenBackAndReopensTheSheetWithTheDraftAndTheReason() throws {
        model.present(project: a)
        model.text = "Add dark mode"
        model.triage()
        commander.answer(.failure(.server(code: "no_flight_control")))
        XCTAssertTrue(stack.isEmpty)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.text, "Add dark mode")
        XCTAssertEqual(model.refusal, "Flight Control isn't turned on for that project on your Mac.")
        let id = try XCTUnwrap(commander.created.first).id
        XCTAssertFalse(flightControl.detailModel(for: id).awaitingCreation)
    }

    /// Not connected: nothing was sent, so the sheet never closes and no screen opens.
    func testNoSocketLeavesTheSheetUpWithTheReason() {
        commander.answerBeforeReturning = .failure(.disconnected)
        model.present(project: a)
        model.text = "Add dark mode"
        model.triage()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.refusal, "Not connected to your Mac, so this wasn't sent.")
    }

    /// A create that may have landed is retried under the same id, so the Mac acks a repeat
    /// instead of making a second intake; a definitive refusal, or other text, starts afresh.
    func testARetryOfAnUnansweredCreateReusesItsIdAndARefusalDoesNot() throws {
        model.present(project: a)
        model.text = "Add dark mode"
        model.triage()
        commander.answer(.failure(.disconnected))   // dropped mid-flight: may have landed
        model.triage()
        XCTAssertEqual(commander.created.count, 2)
        XCTAssertEqual(commander.created[0].id, commander.created[1].id)
        XCTAssertEqual(commander.created[0].token, commander.created[1].token)

        commander.answer(.failure(.server(code: "unknown_project")))
        model.triage()
        XCTAssertNotEqual(commander.created[2].id, commander.created[1].id)

        commander.answer(.failure(.disconnected))
        model.text = "Something else"
        model.triage()
        XCTAssertNotEqual(commander.created[3].id, commander.created[2].id)
    }

    func testAMissingIntakeIsNotGoneWhileItsCreateIsOutstanding() {
        let detail = IntakeDetailModel(id: UUID(), fetcher: fetcher)
        detail.awaitingCreation = true
        detail.refresh()
        XCTAssertFalse(detail.gone)
        detail.awaitingCreation = false
        detail.refresh()
        XCTAssertTrue(detail.gone)
    }

    func testCreateRefusalsAreWorded() {
        XCTAssertEqual(CommandCopy.message(for: .server(code: "unknown_project")), "That project is no longer on your Mac.")
        XCTAssertEqual(CommandCopy.message(for: .server(code: "empty_intent")), "Describe the outcome first.")
    }
}
