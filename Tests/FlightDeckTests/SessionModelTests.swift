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

    func testPinDefaultsToTheTabsOwnID() {
        let session = Session(title: "s", workingDirectory: "/w")
        XCTAssertEqual(session.pinnedConversationID, session.id)
    }

    func testPinCanDifferFromTheTabID() {
        let conversation = UUID()
        let session = Session(
            title: "s", workingDirectory: "/w", pinnedConversationID: conversation
        )
        XCTAssertNotEqual(session.id, conversation)
        XCTAssertEqual(session.pinnedConversationID, conversation)
    }
}
