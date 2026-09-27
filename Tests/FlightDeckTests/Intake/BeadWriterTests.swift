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
    /// End to end over the real planner: "reopen c1, and c1 is blocked by a new bead". The
    /// reopen flips c1 to open before the held edge's recheck reads it, so that recheck must
    /// not demand the triage-time `closed` — FD's own write would fail FD's own check and every
    /// such release would stop `.partiallyReleased` one step short.
    func testReopenPlusHeldEdgeOnTheSameBeadAppliesInFull() async throws {
        let closed = Precondition(status: "closed", assignee: nil)
        let cs = ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),
            .reopen(id: "c1", reason: "r", pre: closed),
            .addEdge(from: .existing("c1"), to: .new("n1"), kind: .blocks)])
        let g = GraphSnapshot(beads: ["c1": BeadSnapshot(id: "c1", title: "c", status: "closed")])
        let steps = ApplyPlanner.plan(try ChangeSetValidator.validate(cs, against: g).get(), skipping: [])
        let r = ReopeningRunner()
        let out = await BeadWriter(runner: r, brPath: "br", actor: "a").apply(steps, project: "/p")
        XCTAssertNil(out.error, out.error ?? "")
        XCTAssertEqual(out.applied, steps.count)
        XCTAssertTrue(r.calls.contains(["br", "dep", "add", "c1", "b9", "--type", "blocks", "--actor", "a"]), "\(r.calls)")
    }
}

/// A `br` whose `show c1` answers closed until `reopen c1` has run, then open — the one
/// piece of state the reopen+held-edge release depends on, which `RecordingRunner`'s fixed
/// replies cannot model.
private final class ReopeningRunner: FlywheelProcessRunner, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    private var reopened = false
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        calls.append([exe] + args)
        switch args.first {
        case "show":
            return (#"[{"id":"c1","title":"c","status":"\#(reopened ? "open" : "closed")"}]"#, 0)
        case "reopen":
            reopened = true
            return ("", 0)
        case "create": return (#"{"id":"b9"}"#, 0)
        default: return ("", 0)
        }
    }
}
