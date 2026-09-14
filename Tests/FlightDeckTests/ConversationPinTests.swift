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
            transcriptDirectory: "/w",
            anchor: nil,
            rows: [7: row(pid: 7, session: conversation)]
        )

        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"))
        XCTAssertEqual(resolution.conversationID, conversation)
    }

    func testWithoutAMatchingRowThereIsNoAnchor() {
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            transcriptDirectory: "/w",
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
            transcriptDirectory: "/w",
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
            transcriptDirectory: "/w",
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
            transcriptDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [:]
        )

        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.conversationID, old)
        XCTAssertEqual(resolution.transcriptDirectory, "/w")
        XCTAssertNil(
            resolution.reportedDirectory,
            "a tick with no rows reports no directory — the transcript value is our own echo"
        )
    }

    func testCwdChangeIsReportedIndependentlyOfTheConversation() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            transcriptDirectory: "/old",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: conversation, cwd: "/new")]
        )

        XCTAssertEqual(resolution.conversationID, conversation)
        XCTAssertEqual(resolution.transcriptDirectory, "/new")
        XCTAssertEqual(resolution.reportedDirectory, "/new")
    }

    // MARK: Reported vs echoed

    /// The distinction the two directory fields exist for. `transcriptDirectory` is always
    /// usable, so it is also always *present*, which makes an echo indistinguishable from a
    /// report of the same path — and `SessionStore` files a tab under a different project on
    /// exactly this value. Anything that acts on new information must read
    /// `reportedDirectory`, so "nothing was reported" has to survive the call.
    func testAnAnchoredRowWithNoCwdReportsNothingAndLeavesTheTranscriptWhereItWas() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            transcriptDirectory: "/a/.claude/worktrees/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: conversation, cwd: "")]
        )

        XCTAssertNil(resolution.reportedDirectory)
        XCTAssertEqual(resolution.transcriptDirectory, "/a/.claude/worktrees/w")
        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"), "still ours")
    }

    /// The same rule on the unanchored branch, which is a separate code path: first
    /// anchoring, and re-anchoring after the anchored `claude` exits.
    func testAFirstAnchoringWithNoCwdReportsNothing() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            transcriptDirectory: "/w",
            anchor: nil,
            rows: [7: row(pid: 7, session: conversation, cwd: "")]
        )

        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"))
        XCTAssertNil(resolution.reportedDirectory)
        XCTAssertEqual(resolution.transcriptDirectory, "/w")
    }

    /// A recycled pid is somebody else's process, so its `cwd` is not a report about us
    /// either — the anchor and the directory have to be dropped together.
    func testARecycledPidReportsNoDirectory() {
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            transcriptDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: UUID(), cwd: "/elsewhere", procStart: "start-b")]
        )

        XCTAssertNil(resolution.reportedDirectory)
        XCTAssertEqual(resolution.transcriptDirectory, "/w")
    }

    func testRepinAndMoveCanHappenTogether() {
        let new = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            transcriptDirectory: "/old",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: new, cwd: "/new")]
        )

        XCTAssertEqual(resolution.conversationID, new)
        XCTAssertEqual(resolution.transcriptDirectory, "/new")
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
                conversationID: conversation, transcriptDirectory: "/w", anchor: nil, rows: rows
            )
            XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
        }
    }

    /// The reopen bug: anchored to an OLD live process for our conversation while a
    /// strictly-newer live process (the reopen's own `claude --resume`) runs the same
    /// conversation. The anchor must hand off to the newer process so the badge follows
    /// the one actually doing the work.
    func testAnchorHandsOffToAStrictlyNewerProcessForTheSameConversation() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            transcriptDirectory: "/w",
            anchor: .init(pid: 7, procStart: "old"),
            rows: [
                7: row(pid: 7, session: conversation, procStart: "old", startedAt: 1),
                9: row(pid: 9, session: conversation, procStart: "new", startedAt: 2),
            ]
        )

        XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
        XCTAssertEqual(resolution.conversationID, conversation)
    }

    /// No flapping: once anchored to the newest, it stays put — the older sibling never
    /// steals the anchor back. This is the fixed point that makes the handoff converge.
    func testAnchorStaysOnTheNewestProcessAndDoesNotFlapBack() {
        let conversation = UUID()
        let rows: [pid_t: ClaudeStatusFile.Entry] = [
            7: row(pid: 7, session: conversation, procStart: "old", startedAt: 1),
            9: row(pid: 9, session: conversation, procStart: "new", startedAt: 2),
        ]
        for _ in 0..<20 {
            let resolution = ConversationPin.resolve(
                conversationID: conversation,
                transcriptDirectory: "/w",
                anchor: .init(pid: 9, procStart: "new"),
                rows: rows
            )
            XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
        }
    }

    /// The supersede check keys off the ANCHORED process's current conversation, not the
    /// pin. A process that itself resumed into a new conversation must still repin (and must
    /// NOT be abandoned for a stranger that happens to hold the old pinned id). Guards the
    /// repin feature against the new code path.
    func testSupersedeDoesNotHijackAProcessThatChangedConversation() {
        let pinned = UUID()
        let moved = UUID()   // the anchored process resumed into this conversation
        let resolution = ConversationPin.resolve(
            conversationID: pinned,
            transcriptDirectory: "/w",
            anchor: .init(pid: 7, procStart: "old"),
            rows: [
                // our anchored process, now on `moved`
                7: row(pid: 7, session: moved, procStart: "old", startedAt: 1),
                // a newer stranger holding the OLD pinned conversation
                9: row(pid: 9, session: pinned, procStart: "new", startedAt: 2),
            ]
        )

        XCTAssertEqual(resolution.conversationID, moved, "still a repin to our process's new conversation")
        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "old"), "did not jump to the stranger")
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
