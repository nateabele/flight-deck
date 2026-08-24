import XCTest
@testable import FleetKit

/// The three commands the phone's fleet list issues: closing a tab, collapsing a project, and
/// opening a session in one.
///
/// Each is checked for its exact key set, not just for the fields it carries. A command that
/// encodes an EXTRA key still decodes and still works, and is still a protocol change nobody
/// agreed to — `Set(json.keys)` is what makes that a failing test rather than a surprise in a
/// packet dump.
final class FleetControlCommandCodingTests: XCTestCase {
    private let target = UUID()

    private func object(_ frame: ClientFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testClosingASessionEncodesAsOneFlatObject() throws {
        let json = try object(.cmd(cid: 3, .closeSession(id: target)))
        XCTAssertEqual(json["t"] as? String, "cmd")
        XCTAssertEqual(json["op"] as? String, "session.close")
        XCTAssertEqual(json["id"] as? String, target.uuidString)
        XCTAssertEqual(Set(json.keys), ["t", "cid", "op", "id"])
    }

    /// **The target state travels, not a toggle.** Two clients that disagree about what is
    /// currently collapsed would otherwise ping-pong a project open and shut; with the value
    /// on the wire the last writer wins and both converge on what it sent.
    func testCollapsingAProjectCarriesTheStateAndNotAToggle() throws {
        let json = try object(.cmd(cid: 4, .setProjectCollapsed(id: target, isCollapsed: true)))
        XCTAssertEqual(json["op"] as? String, "project.collapse")
        XCTAssertEqual(json["isCollapsed"] as? Bool, true)
        XCTAssertEqual(Set(json.keys), ["t", "cid", "op", "id", "isCollapsed"])

        let expanded = try object(.cmd(cid: 5, .setProjectCollapsed(id: target, isCollapsed: false)))
        XCTAssertEqual(expanded["isCollapsed"] as? Bool, false,
                       "the false case must travel too, or expanding is unrepresentable")
    }

    /// **Nothing but the project.** Agent, account and working directory are resolved on the
    /// Mac, and a phone that supplied any of them would be a second place those defaults live
    /// — and a path arriving from off-box would be a directory this process opens on a
    /// client's say-so.
    func testANewSessionCarriesOnlyTheProject() throws {
        let json = try object(.cmd(cid: 6, .newSession(project: target)))
        XCTAssertEqual(json["op"] as? String, "session.new")
        XCTAssertEqual(json["project"] as? String, target.uuidString)
        XCTAssertEqual(Set(json.keys), ["t", "cid", "op", "project"])
        XCTAssertNil(json["path"], "a path must never travel southbound")
    }

    func testAllThreeRoundTripThroughClientFrame() throws {
        let frames: [ClientFrame] = [
            .cmd(cid: 1, .closeSession(id: target)),
            .cmd(cid: 2, .setProjectCollapsed(id: target, isCollapsed: true)),
            .cmd(cid: 3, .setProjectCollapsed(id: target, isCollapsed: false)),
            .cmd(cid: 4, .newSession(project: target)),
        ]
        for sent in frames {
            let data = try JSONEncoder().encode(sent)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), sent)
        }
    }

    /// `id` and `project` are different keys on purpose. A new-session command that reused
    /// `id` would decode as a well-formed command about a SESSION id, and the store would
    /// answer `unknown_project` for a project that exists — a bug that reads as data loss.
    func testTheProjectKeyIsNotTheSessionKey() throws {
        let json = try object(.cmd(cid: 7, .newSession(project: target)))
        XCTAssertNil(json["id"])
        XCTAssertNotNil(json["project"])
    }
}
