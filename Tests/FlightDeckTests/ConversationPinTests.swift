import XCTest
@testable import FlightDeck

final class ConversationPinTests: XCTestCase {
    private func row(
        pid: pid_t, session: UUID, cwd: String = "/w",
        procStart: String = "start-a", startedAt: Double = 1
    ) -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: session, activity: .idle, waitingFor: nil,
              startedAt: startedAt, cwd: cwd, procStart: procStart)
    }

    func testAnchorsToTheRowCarryingOurConversation() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            workingDirectory: "/w",
            anchor: nil,
            rows: [7: row(pid: 7, session: conversation)]
        )

        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"))
        XCTAssertEqual(resolution.conversationID, conversation)
    }

    func testWithoutAMatchingRowThereIsNoAnchor() {
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            workingDirectory: "/w",
            anchor: nil,
            rows: [7: row(pid: 7, session: UUID())]
        )

        XCTAssertNil(resolution.anchor)
    }

    /// The whole feature: same process, new conversation.
    func testAnchoredRowChangingConversationIsARepin() {
        let old = UUID()
        let new = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: old,
            workingDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: new)]
        )

        XCTAssertEqual(resolution.conversationID, new)
        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"))
    }

    /// macOS recycles pids. A familiar pid with an unfamiliar start time is somebody
    /// else's process, and adopting its conversation would be a silent hijack.
    func testRecycledPidLosesTheAnchorRatherThanRepinning() {
        let old = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: old,
            workingDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: UUID(), procStart: "start-b")]
        )

        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.conversationID, old)
    }

    func testVanishedRowLosesTheAnchorAndKeepsThePin() {
        let old = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: old,
            workingDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [:]
        )

        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.conversationID, old)
        XCTAssertEqual(resolution.workingDirectory, "/w")
    }

    func testCwdChangeIsReportedIndependentlyOfTheConversation() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            workingDirectory: "/old",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: conversation, cwd: "/new")]
        )

        XCTAssertEqual(resolution.conversationID, conversation)
        XCTAssertEqual(resolution.workingDirectory, "/new")
    }

    func testRepinAndMoveCanHappenTogether() {
        let new = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            workingDirectory: "/old",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: new, cwd: "/new")]
        )

        XCTAssertEqual(resolution.conversationID, new)
        XCTAssertEqual(resolution.workingDirectory, "/new")
    }

    /// Two processes can legitimately hold one conversation. Anchoring must be
    /// deterministic rather than dictionary-order dependent, and should prefer the
    /// newest process.
    func testAnchoringPrefersTheNewestProcessDeterministically() {
        let conversation = UUID()
        let rows: [pid_t: ClaudeStatusFile.Entry] = [
            7: row(pid: 7, session: conversation, procStart: "old", startedAt: 1),
            9: row(pid: 9, session: conversation, procStart: "new", startedAt: 2),
        ]

        for _ in 0..<20 {
            let resolution = ConversationPin.resolve(
                conversationID: conversation, workingDirectory: "/w", anchor: nil, rows: rows
            )
            XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
        }
    }

    func testConflictedFlagsEveryTabSharingAConversation() {
        let shared = UUID()
        let a = Session(title: "a", workingDirectory: "/w", pinnedConversationID: shared)
        let b = Session(title: "b", workingDirectory: "/w", pinnedConversationID: shared)
        let c = Session(title: "c", workingDirectory: "/w")

        XCTAssertEqual(ConversationPin.conflicted([a, b, c]), [a.id, b.id])
    }

    func testConflictedIsEmptyWhenEveryPinIsDistinct() {
        let a = Session(title: "a", workingDirectory: "/w")
        let b = Session(title: "b", workingDirectory: "/w")

        XCTAssertTrue(ConversationPin.conflicted([a, b]).isEmpty)
    }
}
