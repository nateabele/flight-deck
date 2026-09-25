import XCTest
@testable import FlightDeck

// @MainActor: mirrors FlywheelWatcherTests — FlywheelObserveService is @MainActor, so its
// init and every call below must run on the main actor; annotating the class lets the
// brief's test bodies call it without an explicit `await`.
@MainActor
final class FlywheelObserveServiceTests: XCTestCase {
    func testEnableThenDisableIsIdempotentAndScoped() async {
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        svc.enable(project: dir.path, watchPaths: [])
        svc.enable(project: dir.path, watchPaths: [])       // idempotent — no second watcher
        try? await Task.sleep(for: .milliseconds(150))      // let the priming poll land
        XCTAssertNotNil(svc.projection(forProject: dir.path), "enabled ⇒ a projection exists")
        svc.disable(project: dir.path)
        XCTAssertNil(svc.projection(forProject: dir.path), "disabled ⇒ nil")
    }

    func testKeyStandardizesLikePreferencesStore() {
        XCTAssertEqual(FlywheelObserveService.key("/tmp/p/"), FlywheelObserveService.key("/tmp/p"))
    }

    func testProjectionChangeInvokesNotifierHook() async {
        let fake = MultiRunner(); fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"}]"#, 0)
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        var fired = 0
        svc.onProjectionsChanged = { _ in fired += 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        svc.enable(project: dir.path, watchPaths: [])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(fired, 0)
    }
}
