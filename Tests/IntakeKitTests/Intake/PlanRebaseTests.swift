import XCTest
import IntakeKit

/// `PlanRebase.retarget`, moved out of the app's `EditLayer` (R4) so ThreadRunner can rebase a
/// pending diff the same way the editor carries a stale edit. The three cases `EditLayerTests`
/// pinned before the move, run against the IntakeKit entry point; `EditLayerTests` keeps its own
/// copies, which now go through the forwarder.
final class PlanRebaseTests: XCTestCase {
    /// An accept's reworded line goes onto typing that only touched the next line — the case
    /// `git merge-file` calls a conflict because the hunks are adjacent.
    func testReplayPutsAnAcceptedLineOntoAdjacentTyping() {
        let base = "# P\n\nWe ship on Friday.\n"
        let ours = "# P\n\nWe ship on Monday.\n"
        XCTAssertEqual(PlanRebase.replay(base: base, ours: ours, onto: base + "\nA hand note.\n"),
                       "# P\n\nWe ship on Monday.\n\nA hand note.\n")
        XCTAssertEqual(PlanRebase.replay(base: base, ours: base, onto: "anything"), "anything", "no change to replay")
    }

    /// Nil when the human changed the same line, when it is there twice, or mid-line only.
    func testReplayRefusesARealConflict() {
        let base = "We ship on Friday.\n", ours = "We ship on Monday.\n"
        XCTAssertNil(PlanRebase.replay(base: base, ours: ours, onto: "We ship on Friday, maybe.\n"))
        XCTAssertNil(PlanRebase.replay(base: base, ours: ours, onto: "We ship on Friday.\nWe ship on Friday.\n"))
        XCTAssertNil(PlanRebase.replay(base: base, ours: ours, onto: "Then We ship on Friday.\n"))
        XCTAssertNil(PlanRebase.replay(base: "a\n", ours: "a\nb\n", onto: "a\nc\n"), "an insertion has no old lines to find")
    }

    /// A clean merge is sent for the new head. The merge runs off the main actor even when
    /// called from it, as the editor calls it.
    @MainActor
    func testRetargetCleanMergeSendsForTheNewHead() async {
        let runner = MergeSpy(result: CommandResult(stdout: Data("merged plan\n".utf8), stderr: "", exitCode: 0))
        let outcome = await PlanRebase.retarget(markdown: "edited\n", typedOn: 2, base: "base\n", head: 3,
                                                headPlan: "head\n", runner: runner)
        XCTAssertEqual(outcome, PlanRebase.Retarget(command: .editPlan(checkpoint: 3, markdown: "merged plan\n"), conflict: nil))
        XCTAssertEqual(runner.calls.first?.arguments, ["merge-file", "-p", "ours.md", "base.md", "theirs.md"])
        XCTAssertEqual(runner.calls.first?.files, ["ours.md": "head\n", "base.md": "base\n", "theirs.md": "edited\n"])
        XCTAssertEqual(runner.calls.first?.onMain, false, "git runs off the main actor")
    }

    /// A conflict keeps the edit on the checkpoint it was typed on and reports it.
    func testRetargetConflictKeepsTheEditOnItsCheckpoint() async {
        let runner = MergeSpy(result: CommandResult(stdout: Data("<<<<<<<".utf8), stderr: "", exitCode: 1))
        let outcome = await PlanRebase.retarget(markdown: "edited\n", typedOn: 2, base: "base\n", head: 3,
                                                headPlan: "head\n", runner: runner)
        XCTAssertEqual(outcome, PlanRebase.Retarget(command: .editPlan(checkpoint: 2, markdown: "edited\n"),
                                                    conflict: EditConflict(edits: 2, landedIn: 3)))
    }

    /// The real tool, once: an edit to one section and a round's change to another merge.
    func testRetargetWithRealGitMergesDisjointChanges() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("no git") }
        let base = "# Plan\n\n## A\none\n\n## B\ntwo\n\n## C\nthree\n"
        let head = "# Plan\n\n## A\none, refined\n\n## B\ntwo\n\n## C\nthree\n"
        let edited = "# Plan\n\n## A\none\n\n## B\ntwo\n\n## C\nthree, mine\n"
        let outcome = await PlanRebase.retarget(markdown: edited, typedOn: 2, base: base, head: 3, headPlan: head,
                                                runner: SystemCommandRunner())
        XCTAssertEqual(outcome.command, .editPlan(checkpoint: 3, markdown: "# Plan\n\n## A\none, refined\n\n## B\ntwo\n\n## C\nthree, mine\n"))
        XCTAssertNil(outcome.conflict)
    }
}

/// Records what `git merge-file` would have been handed, and from which thread — a copy of
/// `EditLayerTests`' spy, which is private to its file.
private final class MergeSpy: CommandRunner, @unchecked Sendable {
    struct Call { var arguments: [String]; var files: [String: String]; var onMain: Bool }
    let result: CommandResult
    private(set) var calls: [Call] = []
    init(result: CommandResult) { self.result = result }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        var files: [String: String] = [:]
        for name in ["ours.md", "base.md", "theirs.md"] {
            files[name] = try? String(contentsOf: cwd.appendingPathComponent(name), encoding: .utf8)
        }
        calls.append(Call(arguments: arguments, files: files, onMain: Thread.isMainThread))
        return result
    }
}
