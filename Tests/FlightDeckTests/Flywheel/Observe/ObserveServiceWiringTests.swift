import XCTest
@testable import FlightDeck

final class ObserveServiceWiringTests: XCTestCase {
    @MainActor
    func testDisabledProjectIssuesNoReads() async {
        let fake = MultiRunner()   // records every argv; all default to exit 127
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        // The wiring only calls svc.enable for flywheelEnabled==true projects; simulate the
        // gate by NOT enabling. Assert nothing was read.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fake.argv.isEmpty, "a project that was never enabled must issue zero am/br reads")
    }

    @MainActor
    func testEnabledProjectIssuesScopedReads() async {
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        svc.enable(project: dir.path, watchPaths: [])
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fake.argv.contains { $0.contains(dir.path) }, "reads must be scoped to the enabled project path")
    }
}
