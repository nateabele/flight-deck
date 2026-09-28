import XCTest
import IntakeKit
@testable import FlightDeck

/// `IntakeService.selectedIntake` / `.select` / `.selection(forProject:)` — see
/// `selectedIntake`'s doc comment for the bug this closes: `ProjectView` used `@State` for the
/// Intakes list selection, and SwiftUI resets `@State` whenever the detail view's identity
/// changes, which it does on every project switch (`ProjectView` is keyed by `Repo`). None of
/// these tests need real triage, so they seed intakes straight onto disk via `IntakeStore`
/// rather than going through `capture`, and never touch the default `headless`/`processRunner`
/// `IntakeService` would otherwise spawn real processes with.
@MainActor
final class IntakeServiceSelectionTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeServiceSelectionTests-\(UUID())", isDirectory: true)
        suiteName = "IntakeServiceSelectionTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeService() -> IntakeService {
        IntakeService(store: IntakeStore(root: root), inject: { _, _, _, _ in true },
                      hasSession: { _, _ in false }, defaults: defaults)
    }

    @discardableResult
    private func seed(project: String, intent: String = "Add a note") throws -> UUID {
        let intake = Intake(projectPath: project, intent: intent)
        try IntakeStore(root: root).save(intake)
        return intake.id
    }

    func testSelectionSurvivesProjectSwitch() throws {
        // Seeded before the service exists: `IntakeService` loads `intakes` once, at init,
        // from whatever `IntakeStore` already has on disk — it never re-reads mid-test.
        let a = try seed(project: "/a")
        let b = try seed(project: "/b")
        let svc = makeService()
        svc.select(a, inProject: "/a")
        svc.select(b, inProject: "/b")
        // Selecting in B, the way visiting another project and picking something there would,
        // must not disturb A's own selection — exactly what `ProjectView`'s old `@State` lost
        // on the way back to A.
        XCTAssertEqual(svc.selection(forProject: "/a"), a)
        XCTAssertEqual(svc.selection(forProject: "/b"), b)
    }

    func testSelectionOfDiscardedIntakeReadsNil() throws {
        // Seeded before the service exists — see `testSelectionSurvivesProjectSwitch`'s comment.
        let id = try seed(project: "/a")
        let svc = makeService()
        svc.select(id, inProject: "/a")
        XCTAssertEqual(svc.selection(forProject: "/a"), id)

        svc.discard(id)
        // `intakes(forProject:)` never lists a discarded intake; the stale selection must read
        // nil rather than keep pointing the detail pane at a row the list can no longer draw.
        XCTAssertNil(svc.selection(forProject: "/a"))
    }

    func testSelectionPersistsAcrossServiceInstances() throws {
        let id = try seed(project: "/a")
        let first = makeService()
        first.select(id, inProject: "/a")

        // A fresh instance over the same `UserDefaults` suite is what a relaunch looks like —
        // the selection must come back without either service having stayed alive.
        let relaunched = makeService()
        XCTAssertEqual(relaunched.selection(forProject: "/a"), id)
    }

    // MARK: - Inspector

    /// The inspector's open/closed state is per project and survives a switch away and back —
    /// it was `@State` on `ProjectView`, which SwiftUI resets on a switch away and back (see
    /// `selectedIntake`), so the notes rail closed itself behind the human.
    func testInspectorShownIsPerProjectAndSurvivesSwitch() {
        let svc = makeService()
        XCTAssertFalse(svc.inspectorShown(forProject: "/a"), "hidden by default (spec §3)")
        svc.setInspectorShown(true, inProject: "/a")
        XCTAssertTrue(svc.inspectorShown(forProject: "/a"))
        XCTAssertFalse(svc.inspectorShown(forProject: "/b"), "opening it in one project must not open it in another")
        // Same key normalization as the selection: a trailing slash is the same project.
        XCTAssertTrue(svc.inspectorShown(forProject: "/a/"))
    }

    /// Closing sticks — the original report was an inspector that could not be closed.
    func testInspectorCloses() {
        let svc = makeService()
        svc.setInspectorShown(true, inProject: "/a")
        svc.setInspectorShown(false, inProject: "/a")
        XCTAssertFalse(svc.inspectorShown(forProject: "/a"))
        XCTAssertFalse(makeService().inspectorShown(forProject: "/a"), "a relaunch must not reopen a closed inspector")
    }

    func testInspectorShownPersistsAcrossServiceInstances() {
        makeService().setInspectorShown(true, inProject: "/a")
        let relaunched = makeService()
        XCTAssertTrue(relaunched.inspectorShown(forProject: "/a"))
        XCTAssertFalse(relaunched.inspectorShown(forProject: "/b"))
    }
}
