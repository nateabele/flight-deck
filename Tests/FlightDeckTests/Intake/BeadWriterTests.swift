import XCTest
import IntakeKit
@testable import FlightDeck

/// Records argv and answers canned replies keyed by `"<exe> <args[0]>"` (e.g. `"br create"`),
/// mirroring `MultiRunner` (Observe) — unknown keys return `("", 127)`, "command not found",
/// so a step this test never expects to reach shows up as a loud failure rather than a
/// silent success.
final class RecordingRunner: FlywheelProcessRunner, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    let replies: [String: (String, Int32)]
    init(replies: [String: (String, Int32)]) { self.replies = replies }
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        calls.append([exe] + args)
        let key = ([exe] + args.prefix(1)).joined(separator: " ")
        return replies[key] ?? ("", 127)
    }
}

@MainActor
final class BeadWriterTests: XCTestCase {
    func testCreateThenDependResolvesTempIds() async {
        let r = RecordingRunner(replies: [
            "br create": (#"{"id":"b9"}"#, 0), "br dep": ("", 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "flightdeck-intake:X")
        let out = await w.apply([.create(NewBead(tempId: "n1", title: "T", description: "d")),
                                 .depend(dependent: .new("n1"), dependency: .existing("b1"), kind: .blocks)], project: "/p")
        XCTAssertNil(out.error); XCTAssertEqual(out.applied, 2); XCTAssertEqual(out.idMap, ["n1": "b9"])
        XCTAssertEqual(r.calls[1], ["br", "dep", "add", "b9", "b1", "--type", "blocks", "--actor", "flightdeck-intake:X"])
    }
    func testFailureMidwayRecordsPartial() async {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br dep": ("database is locked", 1)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([.create(NewBead(tempId: "n1", title: "T", description: "d")),
                                 .depend(dependent: .new("n1"), dependency: .existing("b1"), kind: .blocks),
                                 .update(id: "b1", set: FieldSet(title: "x"))], project: "/p")
        XCTAssertEqual(out.applied, 1)
        XCTAssertTrue(out.error?.contains("dep") == true)
        XCTAssertEqual(r.calls.count, 2)                // stopped; never reached update
    }
    func testRecheckMismatchStops() async {
        let r = RecordingRunner(replies: ["br show": (#"[{"id":"b1","title":"t","status":"in_progress","assignee":"X"}]"#, 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([.recheck(id: "b1", pre: Precondition(status: "open", assignee: nil)),
                                 .update(id: "b1", set: FieldSet(title: "x"))], project: "/p")
        XCTAssertEqual(out.applied, 0); XCTAssertNotNil(out.error)
    }
    func testEmptyPlanSyncsAndReturnsCleanOutcome() async {
        let r = RecordingRunner(replies: ["br sync": ("", 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([], project: "/p")
        XCTAssertNil(out.error); XCTAssertEqual(out.applied, 0)
        XCTAssertEqual(r.calls.last, ["br", "sync", "--flush-only", "--actor", "a"])
    }
    func testSuccessfulApplyFlushesSync() async {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([.create(NewBead(tempId: "n1", title: "T", description: "d"))], project: "/p")
        XCTAssertNil(out.error)
        XCTAssertEqual(r.calls.last, ["br", "sync", "--flush-only", "--actor", "a"])
    }
    func testReopenPostsCommentThenReopens() async {
        let r = RecordingRunner(replies: ["br reopen": ("", 0), "br comments": ("", 0), "br sync": ("", 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "flightdeck-intake:X")
        let out = await w.apply([.reopen(id: "b1", reason: "needs more work")], project: "/p")
        XCTAssertNil(out.error); XCTAssertEqual(out.applied, 1)
        XCTAssertEqual(r.calls[0], ["br", "reopen", "b1", "--actor", "flightdeck-intake:X"])
        XCTAssertEqual(r.calls[1], ["br", "comments", "add", "b1",
                                     "Reopened by Flight Deck intake: needs more work", "--actor", "flightdeck-intake:X"])
    }
    /// `FlywheelProcessRunner` discards stderr, so a failure with empty stdout (a real
    /// possibility — `br` sometimes writes only to stderr) must still name what happened.
    /// Without the exit code in the message, this case degrades to `"reopen b1: "` — the
    /// step description with no information about the failure at all.
    func testFailureWithEmptyStdoutStillReportsTheExitCode() async {
        let r = RecordingRunner(replies: ["br reopen": ("", 1)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([.reopen(id: "b1", reason: "r")], project: "/p")
        XCTAssertEqual(out.applied, 0)
        XCTAssertTrue(out.error?.contains("reopen b1") == true, out.error ?? "nil")
        XCTAssertTrue(out.error?.contains("exit 1") == true, out.error ?? "nil")
    }
}
