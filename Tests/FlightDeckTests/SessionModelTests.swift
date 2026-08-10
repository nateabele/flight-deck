// Tests/FlightDeckTests/SessionModelTests.swift
import XCTest
@testable import FlightDeck

final class SessionModelTests: XCTestCase {
    func testRepoDisplayNameIsLastPathComponent() {
        let repo = Repo(url: URL(fileURLWithPath: "/Users/nate/code/flight-deck", isDirectory: true))
        XCTAssertEqual(repo.displayName, "flight-deck")
        XCTAssertTrue(repo.sessions.isEmpty)
    }

    func testSessionCarriesTitleAndWorkingDirectory() {
        let session = Session(title: "session 1", workingDirectory: "/tmp")
        XCTAssertEqual(session.title, "session 1")
        XCTAssertEqual(session.workingDirectory, "/tmp")
    }
}
