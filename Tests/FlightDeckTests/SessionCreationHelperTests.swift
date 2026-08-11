import XCTest
@testable import FlightDeck

final class SessionCreationHelperTests: XCTestCase {
    func testRoutesToNewSessionWhenSessionsExist() {
        XCTAssertEqual(SessionCreateAction.forState(hasSessions: true), .newSession)
    }

    /// With nothing open there is no project to create a session in, so ⌘N must fall
    /// through to Add Project.
    func testRoutesToAddProjectWhenEmpty() {
        XCTAssertEqual(SessionCreateAction.forState(hasSessions: false), .addProject)
    }

    func testDirectoryResolvesToItself() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            SessionCreateAction.projectDirectory(for: dir).standardizedFileURL,
            dir.standardizedFileURL
        )
    }

    /// Dropping a file from a repo adds the repo, not nothing.
    func testFileResolvesToItsParentDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("README.md")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SessionCreateAction.projectDirectory(for: file).standardizedFileURL,
            dir.standardizedFileURL
        )
    }

    func testNonexistentPathResolvesToItsParent() {
        let missing = URL(fileURLWithPath: "/nope/does-not-exist/file.txt")
        XCTAssertEqual(
            SessionCreateAction.projectDirectory(for: missing).path,
            "/nope/does-not-exist"
        )
    }
}
