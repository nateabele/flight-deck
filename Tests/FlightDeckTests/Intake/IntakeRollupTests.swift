import XCTest
import IntakeKit
@testable import FlightDeck

/// `SessionStore.collapsedStatus(forProjectAt:)` folding in `IntakeService.attentionCount` —
/// so a project whose intake is sitting on an unanswered triage question still shows up as
/// `.waiting` in the collapsed header, the same as a session with a permission prompt open.
///
/// `store.intakeService` is a lazy var pointed at `FlightDeckApp.stateDirectory()`, which reads
/// `UserDefaults.standard`. Overriding `FlightDeckStateDir` to a scratch directory for the
/// duration of each test — the same flag a real debug launch uses to run against a *copy* of
/// state — is what lets these cases seed a fixture intake on disk without ever touching the
/// developer's real `~/Library/Application Support/Flight Deck`.
@MainActor
final class IntakeRollupTests: XCTestCase {
    private var scratchDir: URL!
    private var previousStateDir: String?

    override func setUp() {
        super.setUp()
        previousStateDir = UserDefaults.standard.string(forKey: "FlightDeckStateDir")
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeRollupTests-\(UUID())", isDirectory: true)
        UserDefaults.standard.set(scratchDir.path, forKey: "FlightDeckStateDir")
    }

    override func tearDown() {
        if let previousStateDir {
            UserDefaults.standard.set(previousStateDir, forKey: "FlightDeckStateDir")
        } else {
            UserDefaults.standard.removeObject(forKey: "FlightDeckStateDir")
        }
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence), persistence)
    }

    private var intakesRoot: URL { scratchDir.appendingPathComponent("intakes", isDirectory: true) }

    func testProjectWithAnIntakeNeedingAnswersRollsUpToWaiting() throws {
        let (store, _) = makeStore()
        let projectURL = URL(fileURLWithPath: "/w/a", isDirectory: true)
        store.newSession(in: projectURL)
        let project = store.repos[0].id

        var intake = Intake(projectPath: projectURL.standardizedFileURL.path, intent: "Add a note")
        intake.state = .needsAnswers
        try IntakeStore(root: intakesRoot).save(intake)

        let status = store.collapsedStatus(forProjectAt: project)

        XCTAssertEqual(status?.activity, .waiting)
        XCTAssertEqual(status?.waitingFor, "1 intake needs you")
    }

    /// Plural wording, and the tie-break against a real busy session: an intake waiting on the
    /// human outranks a session merely working, matching `.waiting` > `.busy` in `summaryRank`.
    func testTwoIntakesOutrankABusySession() throws {
        let (store, _) = makeStore()
        let projectURL = URL(fileURLWithPath: "/w/b", isDirectory: true)
        let a = store.newSession(in: projectURL)
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy)])

        let path = projectURL.standardizedFileURL.path
        for _ in 0..<2 {
            var intake = Intake(projectPath: path, intent: "Add a note")
            intake.state = .review
            try IntakeStore(root: intakesRoot).save(intake)
        }

        let status = store.collapsedStatus(forProjectAt: project)

        XCTAssertEqual(status?.activity, .waiting)
        XCTAssertEqual(status?.waitingFor, "2 intakes need you")
    }

    /// The hazard this rollup risks: `IntakeService.init` reads `IntakeStore.all()`, which lists
    /// `root`'s contents but never creates it, so a project with no intakes must not leave a
    /// stray `intakes/` directory behind just because its header asked for a status.
    func testCollapsedStatusDoesNotCreateTheIntakesDirectoryWhenThereIsNoIntake() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/c", isDirectory: true))
        let project = store.repos[0].id

        _ = store.collapsedStatus(forProjectAt: project)

        XCTAssertFalse(FileManager.default.fileExists(atPath: intakesRoot.path))
    }
}
