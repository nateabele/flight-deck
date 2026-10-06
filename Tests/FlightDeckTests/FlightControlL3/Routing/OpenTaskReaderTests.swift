import XCTest
import IntakeKit
@testable import FlightDeck

@MainActor
final class OpenTaskReaderTests: XCTestCase {
    func testItListsOpenTasksAsJSON() async throws {
        let list = String(decoding: try RoutingFixtures.data("br-list-open.json"), as: UTF8.self)
        let r = RecordingRunner(replies: ["br list": (list, 0)])
        let result = await BrOpenTaskReader(runner: r, brPath: "br").openTasks(project: "/p")
        XCTAssertEqual(r.calls.first, ["br", "list", "--status", "open", "--json"])
        XCTAssertEqual(try result.get().map(\.id), ["fx-a", "fx-b"])
    }

    func testAFailureSaysWhy() async {
        let r = RecordingRunner(replies: ["br list": ("no database here", 1)])
        let result = await BrOpenTaskReader(runner: r, brPath: "br").openTasks(project: "/p")
        XCTAssertEqual(result, .failure(OpenTaskReadError(message: "br list exited 1: no database here")))
    }
}
