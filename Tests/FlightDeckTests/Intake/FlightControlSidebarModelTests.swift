import AppKit
import FleetKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The sidebar indicator over a real `IntakeService` and a real `ProjectHeaderRow`: it follows
/// the service, a click lands on the right plan, and a publish that changes nothing the
/// indicator shows redraws nothing but the row the store already redraws (`RenderProbe`).
///
/// Every intake is seeded on disk and the store's tapes are PAUSED ones: a running tape would
/// make the store's real runner controller try to resume it.
@MainActor
final class FlightControlSidebarModelTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlightControlSidebarModelTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let project = URL(fileURLWithPath: "/w/larkos", isDirectory: true)
    private var path: String { project.standardizedFileURL.path }

    @discardableResult
    private func seed(_ state: IntakeState, _ intent: String, at age: TimeInterval = 0) throws -> Intake {
        var i = Intake(projectPath: path, intent: intent, createdAt: Date().addingTimeInterval(-age))
        i.state = state
        if state == .shaping {
            i.chosenPreset = .featurePlan
            i.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        }
        try IntakeStore(root: root).save(i)
        return i
    }

    private func tapeStore(_ id: UUID) -> TapeStore {
        TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id))
    }

    private func writeTape(_ id: UUID, _ edit: (inout Tape) -> Void, modified: Date = Date()) throws {
        var tape = tapeStore(id).loadTape()
        edit(&tape)
        try tapeStore(id).saveTape(tape)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: tapeStore(id).tapeURL.path)
    }

    private func makeStore() -> SessionStore {
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(path, ProjectSettings(flywheelEnabled: true))
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: preferences, intakesRoot: root)
        store.newSession(in: project)
        return store
    }

    // MARK: the model

    func testTheModelFollowsTheServiceAndPublishesOnlyChanges() throws {
        let asking = try seed(.needsAnswers, "Add a crew calendar")
        let store = makeStore()
        let model = FlightControlSidebarModel()
        model.attach(service: store.intakeService, path: path)
        XCTAssertEqual(model.status.kind, .needsYou)
        XCTAssertEqual(model.status.target, asking.id)

        var published = 0
        let sub = model.objectWillChange.sink { published += 1 }
        defer { sub.cancel() }
        model.refresh()
        model.refresh()
        XCTAssertEqual(published, 0, "an unchanged status is not republished")

        XCTAssertTrue(store.intakeService.discard(asking.id))
        XCTAssertTrue(spinRunLoop { model.status.kind == .idle }, "the service's publish reaches the model")
        XCTAssertGreaterThan(published, 0)
    }

    func testAProjectWithFlightControlOffNeverBuildsOrReadsTheService() throws {
        try seed(.needsAnswers, "Add a crew calendar")
        let model = FlightControlSidebarModel()
        model.attach(service: nil, path: path)
        XCTAssertEqual(model.status, .idle)
    }

    // MARK: the click

    func testClickOpensTheProjectAndSelectsThePlanThatNeedsYou() throws {
        try seed(.shaping, "Running plan", at: 10)
        let asking = try seed(.needsAnswers, "Question plan", at: 100)
        let store = makeStore()
        let service = store.intakeService
        try writeTape(try XCTUnwrap(service.intakes(forProject: path).first { $0.state == .shaping }).id) {
            $0.status = .paused
        }
        service.pollTapes()
        let repo = try XCTUnwrap(store.repos.first)
        let model = FlightControlSidebarModel()
        model.attach(service: service, path: path)
        XCTAssertEqual(model.status.kind, .needsYou)
        XCTAssertEqual(model.status.attentionCount, 2, "the paused round and the open question")

        store.deselectProject()
        model.open(in: store, repoID: repo.id)

        XCTAssertEqual(store.selectedProjectID, repo.id, "the project's own view")
        XCTAssertEqual(service.selection(forProject: path), model.status.target)
        XCTAssertNotNil(service.selection(forProject: path))
        XCTAssertTrue([asking.id, service.intakes(forProject: path).first { $0.state == .shaping }!.id]
            .contains(try XCTUnwrap(service.selection(forProject: path))))
    }

    func testClickWithNothingToShowDoesNothing() throws {
        let store = makeStore()
        let model = FlightControlSidebarModel()
        model.attach(service: store.intakeService, path: path)
        store.deselectProject()
        model.open(in: store, repoID: try XCTUnwrap(store.repos.first).id)
        XCTAssertNil(store.selectedProjectID)
    }

    // MARK: redraws

    /// `settleRenders` for an async test. This one must SUSPEND between looks: a nested
    /// `RunLoop.run` inside a main-actor task does not drain `DispatchQueue.main`, which is where
    /// the model defers its refresh, so only an `await` lets that block (and SwiftUI) run.
    private func settle() async {
        var last = RenderProbe.counts
        var quiet = 0
        for _ in 0..<200 where quiet < 3 {
            try? await Task.sleep(for: .milliseconds(150))
            let now = RenderProbe.counts
            if now == last { quiet += 1 } else { quiet = 0; last = now }
        }
    }

    /// The header observes the whole store, so a service publish re-evaluates it: that is the
    /// existing cost. What the indicator adds is a body that runs only when its status changes.
    func testAPublishThatChangesNothingTheIndicatorShowsRedrawsNoIndicator() async throws {
        let shaping = try seed(.shaping, "LarkOS plan")
        try writeTape(shaping.id, { $0.status = .paused }, modified: Date().addingTimeInterval(-60))
        let store = makeStore()
        let service = store.intakeService
        service.pollTapes()
        await service.convergenceFold(for: shaping.id)?.value
        let repo = try XCTUnwrap(store.repos.first)
        let size = NSSize(width: 320, height: 40)
        let host = NSHostingView(rootView: ProjectHeaderRow(store: store, repo: repo, isSidebarFocused: false, onClose: {})
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await settle()
        XCTAssertGreaterThan(RenderProbe.counts["fcIndicator"] ?? 0, 0, "needs-you draws a glyph: \(RenderProbe.counts)")

        // 1. A tape write the indicator cannot show: the runner acked a command. The store
        //    republishes (the row re-evaluates), the status is the same.
        var quiet: [[String: Int]] = []
        for n in 1...5 {
            await settle()
            RenderProbe.reset()
            try writeTape(shaping.id, { $0.ackedCommandSeq = n }, modified: Date().addingTimeInterval(Double(n)))
            service.pollTapes()
            await settle()
            quiet.append(RenderProbe.counts)
        }
        let header = quiet.map { $0["projectHeader"] ?? 0 }.reduce(0, +)
        let indicator = quiet.map { $0["fcIndicator"] ?? 0 }.reduce(0, +)
        print("FC-SIDEBAR-REDRAW unchanged-status publishes=5 headerBodies=\(header) indicatorBodies=\(indicator)")
        XCTAssertGreaterThan(header, 0, "the probe sees the row redraw on a publish: \(quiet)")
        XCTAssertEqual(indicator, 0, "an unchanged status redrew the indicator: \(quiet)")

        // 2. A change it does show: the plan is stopped. One indicator body, with new words.
        RenderProbe.reset()
        try writeTape(shaping.id, { $0.status = .stopped }, modified: Date().addingTimeInterval(30))
        service.pollTapes()
        await settle()
        print("FC-SIDEBAR-REDRAW changed-status counts=\(RenderProbe.counts)")
        XCTAssertEqual(RenderProbe.counts["fcIndicator"], 1, "\(RenderProbe.counts)")
    }
}
