import XCTest
import IntakeKit
@testable import FlightDeck

/// `SessionStore.collapsedStatus(forProjectAt:)` is about SESSIONS only. A plan that needs you
/// used to enter it as a synthetic `.waiting`, so it read as a tab needing you; it has its own
/// indicator now (`FlightControlSidebarStatus`), and these cases pin that the two stay apart.
///
/// Each case hands its store a scratch `intakesRoot`, so the fixture intakes seeded here are
/// the only ones the store can see, and the developer's real
/// `~/Library/Application Support/Flight Deck/intakes` is never read — let alone rewritten by
/// `IntakeService.init`'s launch recovery.
@MainActor
final class IntakeRollupTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeRollupTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence, intakesRoot: intakesRoot), persistence)
    }

    private var intakesRoot: URL { scratchDir.appendingPathComponent("intakes", isDirectory: true) }

    func testAPlanNeedingAnswersDoesNotMakeTheCollapsedProjectWaiting() throws {
        let (store, _) = makeStore()
        let projectURL = URL(fileURLWithPath: "/w/a", isDirectory: true)
        store.newSession(in: projectURL)
        let project = store.repos[0].id

        var intake = Intake(projectPath: projectURL.standardizedFileURL.path, intent: "Add a note")
        intake.state = .needsAnswers
        try IntakeStore(root: intakesRoot).save(intake)

        XCTAssertNil(store.collapsedStatus(forProjectAt: project))
    }

    /// Plans needing you neither outrank nor replace a busy session's own status.
    func testPlansLeaveABusySessionsStatusAlone() throws {
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

        XCTAssertEqual(store.collapsedStatus(forProjectAt: project)?.activity, .busy)
    }

    /// The hazard a status read risks: `IntakeService.init` reads `IntakeStore.all()`, which lists
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
