import XCTest
import IntakeKit
@testable import FlightDeck

/// The hand-off prompt is the only thing the new agent knows about the old one, and the planner
/// decides when there is a hand-off at all. These pin the spec's wording line by line (§5.5),
/// the missing-transcript fallback (§7), and that only a quota crossing — never a full local
/// pool or a renamed account — produces a request.
final class HandoffPromptTests: XCTestCase {
    private let task = TaskRef(id: "fd-3x9", project: URL(fileURLWithPath: "/p/proj"))
    private let block = ExecutionBlock(kind: "tests", agent: .claude, model: "opus", pool: "claude-default",
                                       source: AssignmentSource(by: .rule, reason: "r", at: Date(timeIntervalSince1970: 0)))

    private func request(transcript: TranscriptPointer?, files: [String]) -> HandoffRequest {
        HandoffRequest(task: task, block: block, oldAgent: "BlueLake", oldSession: SessionRef(id: UUID(), agentName: "BlueLake"),
                       transcript: transcript, reservedFiles: files, fromAccount: UsageRefs.work)
    }

    func testRendersEverySpecLineForAPathPointer() {
        let p = TranscriptPointer(locator: .path("/Users/n/.claude/projects/-p-proj/abc.jsonl"), format: "JSONL",
                                  howToRead: "Read the last 200 lines first.")
        XCTAssertEqual(HandoffPrompt.render(request(transcript: p, files: ["Sources/A.swift", "Sources/B.swift"])), """
        You are continuing task fd-3x9, started by BlueLake, which stopped because its account reached its usage limit.
        Its transcript is at /Users/n/.claude/projects/-p-proj/abc.jsonl (JSONL). Read it to understand what was done and decided.
        Read the last 200 lines first.
        Run `git status` and `git diff` before changing anything. The work may be half done.
        Re-reserve these files before editing: Sources/A.swift, Sources/B.swift.
        Then finish the task as described in `br show fd-3x9`.
        """)
    }

    func testACommandPointerSaysToRunIt() {
        let p = TranscriptPointer(locator: .command("opencode export ses_1"), format: "OpenCode session export, JSON", howToRead: "Read the messages array.")
        let text = HandoffPrompt.render(request(transcript: p, files: ["a"]))
        XCTAssertTrue(text.contains("Its transcript is available from `opencode export ses_1` (OpenCode session export, JSON). Read it to understand what was done and decided."))
    }

    func testHowToReadIsOmittedWhenEmpty() {
        let p = TranscriptPointer(locator: .path("/t.jsonl"), format: "JSONL", howToRead: "")
        let text = HandoffPrompt.render(request(transcript: p, files: ["a"]))
        XCTAssertTrue(text.contains("Its transcript is at /t.jsonl (JSONL). Read it to understand what was done and decided."))
        let lines = text.split(separator: "\n")
        XCTAssertFalse(text.contains("\n\n"), "no blank line from omitted howToRead")
    }

    func testAMissingTranscriptLeansOnGitAndTheTaskNotes() {
        let text = HandoffPrompt.render(request(transcript: nil, files: ["a"]))
        XCTAssertTrue(text.contains("Its transcript is not available. Lean on `git diff` and the task's notes in `br show fd-3x9` to understand what was done and decided."))
        XCTAssertFalse(text.contains("Its transcript is at"))
    }

    func testNoReservationsSaysToReserveRatherThanListingNothing() {
        let text = HandoffPrompt.render(request(transcript: nil, files: []))
        XCTAssertTrue(text.contains("It held no file reservations. Reserve the files you will edit with Agent Mail before you edit them."))
        XCTAssertFalse(text.contains("Re-reserve these files before editing: ."))
    }

    private func snapshot(lease: AccountLease?, task: TaskRef? = TaskRef(id: "fd-3x9", project: URL(fileURLWithPath: "/p/proj"))) -> SwarmAgentSnapshot {
        SwarmAgentSnapshot(session: SessionRef(id: UUID(), agentName: "BlueLake"), agentName: "BlueLake", block: block, lease: lease, task: task)
    }

    private func planner(_ reader: CapacityReader, files: [String] = ["Sources/A.swift"]) -> LedgerHandoffPlanner {
        let pointer = TranscriptPointer(locator: .path("/t.jsonl"), format: "JSONL", howToRead: "tail")
        return LedgerHandoffPlanner(reader: reader, transcript: { _ in pointer }, reservedFiles: { _ in files })
    }

    func testRequestOnlyWhenTheLeasedAccountIsOverHard() {
        let reader = FakeCapacityReader()
        let lease = AccountLease(pool: "claude-default", account: UsageRefs.work)
        reader.byPool["claude-default"] = [AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.9, state: .overSoft, resetsAt: nil)]
        XCTAssertNil(planner(reader).request(for: snapshot(lease: lease)), "over soft takes no new work but keeps what it has")
        reader.byPool["claude-default"] = [AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.97, state: .overHard, resetsAt: nil)]
        let r = planner(reader).request(for: snapshot(lease: lease))
        XCTAssertEqual(r?.fromAccount, UsageRefs.work)
        XCTAssertEqual(r?.reservedFiles, ["Sources/A.swift"])
        XCTAssertEqual(r?.transcript?.locator, .path("/t.jsonl"))
        XCTAssertEqual(r?.oldAgent, "BlueLake")
    }

    func testARenamedAccountStillMatchesItsLease() {
        let reader = FakeCapacityReader()
        var renamed = UsageRefs.work; renamed.label = "Work (renamed)"
        reader.byPool["claude-default"] = [AccountHeadroom(account: renamed, worstUtilization: 1, state: .overHard, resetsAt: nil)]
        XCTAssertNotNil(planner(reader).request(for: snapshot(lease: AccountLease(pool: "claude-default", account: UsageRefs.work))),
                        "matching on the label would strand an agent on an exhausted account after a rename")
    }

    func testNoRequestWithoutALeaseATaskOrForALocalSlot() {
        let reader = FakeCapacityReader()
        let slot = AccountRef(agent: .gemini, id: nil, label: "Ollama")
        reader.byPool["ollama"] = [AccountHeadroom(account: slot, worstUtilization: 1, state: .overHard, resetsAt: nil)]
        XCTAssertNil(planner(reader).request(for: snapshot(lease: AccountLease(pool: "ollama", account: slot))),
                     "a full local pool is concurrency, not quota: nothing to hand off")
        XCTAssertNil(planner(reader).request(for: snapshot(lease: nil)))
        reader.byPool["claude-default"] = [AccountHeadroom(account: UsageRefs.work, worstUtilization: 1, state: .overHard, resetsAt: nil)]
        XCTAssertNil(planner(reader).request(for: snapshot(lease: AccountLease(pool: "claude-default", account: UsageRefs.work), task: nil)))
    }
}
