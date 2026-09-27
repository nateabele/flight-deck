import Combine
import XCTest
import IntakeKit
@testable import FlightDeck

/// How `SessionStore` owns its `IntakeService`: where it reads intakes from, and that a
/// change inside the service reaches every view observing only the store.
@MainActor
final class SessionStoreIntakeWiringTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreIntakeWiringTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Hundreds of tests build a bare store, and `collapsedStatus` builds the lazy service on
    /// first read. Pointed at the real `<state dir>/intakes`, its launch recovery would rewrite
    /// the developer's live `.triaging`/`.releasing` intakes to `.interrupted` — from a unit
    /// test. Only `FlightDeckApp.makeStore` names the real root; everything else gets none.
    func testAStoreGivenNoIntakesRootNeverResolvesTheRealOne() {
        let store = SessionStore(provider: nil, persistence: nil)
        let real = (FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
            .appendingPathComponent("intakes", isDirectory: true)
        XCTAssertNotEqual(store.resolvedIntakesRoot.standardizedFileURL.path, real.standardizedFileURL.path)
        XCTAssertFalse(store.resolvedIntakesRoot.standardizedFileURL.path
            .hasPrefix(FileSessionPersistence.defaultDirectory().standardizedFileURL.path))
    }

    func testAnInjectedRootIsWhereTheServiceReads() throws {
        var intake = Intake(projectPath: "/w/a", intent: "x")
        intake.state = .needsAnswers
        try IntakeStore(root: root).save(intake)
        let store = SessionStore(provider: nil, persistence: nil, intakesRoot: root)
        XCTAssertEqual(store.intakeService.attentionCount(forProject: "/w/a"), 1)
    }

    /// `ProjectHeaderRow` and `collapsedStatus` read the service through the store and observe
    /// only the store, so without the forward an intake that stopped needing the human left
    /// its orange badge on the header until something unrelated republished the store.
    func testAnIntakeChangeRepublishesTheStore() throws {
        var intake = Intake(projectPath: "/w/a", intent: "x")
        intake.state = .needsAnswers
        try IntakeStore(root: root).save(intake)
        let store = SessionStore(provider: nil, persistence: nil, intakesRoot: root)
        let service = store.intakeService
        var fired = 0
        let sub = store.objectWillChange.sink { fired += 1 }
        defer { sub.cancel() }

        XCTAssertTrue(service.discard(intake.id))

        XCTAssertGreaterThan(fired, 0)
    }
}
