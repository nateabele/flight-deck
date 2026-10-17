import IntakeKit
import XCTest
@testable import FlightDeck

final class TaskGraphModelTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private let open = Precondition(status: "open", assignee: nil)
    private let closed = Precondition(status: "closed", assignee: nil)
    private let graph = GraphSnapshot(beads: [
        "fd-9": BeadSnapshot(id: "fd-9", title: "Font at surface init", status: "open"),
        "fd-4": BeadSnapshot(id: "fd-4", title: "Prefs v1", status: "closed"),
        "fd-12": BeadSnapshot(id: "fd-12", title: "Settings window", status: "in_progress"),
    ])

    private func task(_ t: String, _ title: String, description: String = "d", acceptance: String? = "a", priority: Int = 2) -> ChangeOp {
        .createBead(NewBead(tempId: t, title: title, priority: priority, description: description, acceptance: acceptance,
                            labels: ["prefs"], taskKind: "storage"))
    }

    private func set(_ ops: [ChangeOp]) -> ChangeSet { ChangeSet(graphObservedAt: at, ops: ops) }

    /// Every task with all its fields, existing ones titled from the graph, and each edge on
    /// both of the tasks it joins.
    func testReadsEveryTaskInFullWithItsDependenciesBothWays() throws {
        let model = TaskGraphModel(changeSet: set([
            task("t1", "Store font size", description: "Per project.", acceptance: "Unit: round-trips."),
            task("t2", "Apply font size"),
            .addEdge(from: .new("t2"), to: .new("t1"), kind: .blocks),
            .addEdge(from: .new("t1"), to: .existing("fd-12"), kind: .blocks),
            .editBead(id: "fd-9", set: FieldSet(title: "Resolve font at surface init"), pre: open, delivery: nil),
            .followUp(tempId: "t3", of: "fd-4", title: "Migrate prefs", description: "Move v1 keys.", pre: closed),
        ]), graph: graph)
        let byID = Dictionary(uniqueKeysWithValues: model.tasks.map { ($0.id, $0) })
        let t1 = try XCTUnwrap(byID["new:t1"])
        XCTAssertEqual(t1.description, "Per project.")
        XCTAssertEqual(t1.acceptance, "Unit: round-trips.")
        XCTAssertEqual(t1.labels, ["prefs"])
        XCTAssertEqual(t1.taskKind, "storage")
        XCTAssertEqual(t1.dependsOn, [.init(id: "fd-12", title: "Settings window")])
        XCTAssertEqual(t1.neededBy, [.init(id: "new:t2", title: "Apply font size")])
        XCTAssertEqual(byID["fd-12"]?.origin, .existing)
        XCTAssertEqual(byID["fd-12"]?.status, "in_progress")
        XCTAssertEqual(byID["fd-9"]?.origin, .edit)
        XCTAssertEqual(byID["fd-9"]?.title, "Font at surface init", "the task as it is; the edit is listed with it")
        XCTAssertEqual(byID["fd-9"]?.edits?.title, "Resolve font at surface init")
        XCTAssertEqual(byID["new:t3"]?.origin, .followUp(of: "fd-4"))
        XCTAssertEqual(byID["new:t3"]?.relatedTo, [.init(id: "fd-4", title: "Prefs v1")])
        XCTAssertEqual(model.newCount, 3)
        XCTAssertEqual(model.existingChangedCount, 1)
        XCTAssertEqual(model.edgeCount, 3)
    }

    /// The page reads in the order the work can be done.
    func testEachTaskComesAfterWhatItDependsOn() {
        let model = TaskGraphModel(changeSet: set([
            task("c", "C"), task("a", "A"), task("b", "B"),
            .addEdge(from: .new("c"), to: .new("b"), kind: .blocks),
            .addEdge(from: .new("b"), to: .new("a"), kind: .blocks),
        ]), graph: nil)
        XCTAssertEqual(model.tasks.map(\.id), ["new:a", "new:b", "new:c"])
    }

    func testLoadsFromACheckpointAndFollowsTheNewestWithTasks() throws {
        let data = try set([task("t1", "One")]).encoded()
        let tape = Tape(checkpoints: [
            Checkpoint(id: 1, parent: nil, stage: .refine, round: 1, major: true, createdAt: at),
            Checkpoint(id: 2, parent: 1, stage: .encode, round: 0, major: true, createdAt: at),
            Checkpoint(id: 3, parent: 2, stage: .polish, round: 1, major: false, createdAt: at),
        ])
        let load: (Int, String) -> Data? = { id, name in name == "changeset.json" && id >= 2 ? data : nil }
        XCTAssertNil(TaskGraphModel.load(checkpoint: 1, loadFile: load), "before Encode there are no tasks")
        XCTAssertEqual(try TaskGraphModel.load(checkpoint: 3, loadFile: load)?.get().tasks.map(\.title), ["One"])
        XCTAssertEqual(TaskGraphModel.latestWithChangeSet(upTo: 3, tape: tape, loadFile: load), 3)
        XCTAssertEqual(TaskGraphModel.previousWithChangeSet(before: 3, tape: tape, loadFile: load), 2)
        XCTAssertNil(TaskGraphModel.previousWithChangeSet(before: 2, tape: tape, loadFile: load))
        XCTAssertEqual(TaskGraphModel.load(checkpoint: 2, loadFile: { _, _ in Data("x".utf8) }), .failure(.unreadable))
    }

    // MARK: - Task Changes

    func testAddedRemovedAndChangedTasksWithWhatChanged() {
        let old = TaskGraphModel(changeSet: set([
            task("keep", "Keep"), task("gone", "Gone"), task("edit", "Edit me", description: "Store the size."),
            .addEdge(from: .new("edit"), to: .new("gone"), kind: .blocks),
        ]), graph: graph)
        let new = TaskGraphModel(changeSet: set([
            task("keep", "Keep"), task("edit", "Edit me", description: "Store the font size.", priority: 1), task("fresh", "Fresh"),
            .addEdge(from: .new("edit"), to: .new("fresh"), kind: .blocks),
        ]), graph: graph)
        let diff = TaskGraphDiff(old: old, new: new)
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.changed, 1)
        XCTAssertEqual(diff.unchanged, 1)
        let changed = diff.entries.first { $0.kind == .changed }
        XCTAssertEqual(changed?.id, "new:edit")
        XCTAssertEqual(changed?.fields, [
            .init(field: "Priority", old: "P2", new: "P1"),
            .init(field: "Description", old: "Store the size.", new: "Store the font size."),
        ])
        XCTAssertEqual(changed?.links, [.init(relation: "Depends on", added: [.init(id: "new:fresh", title: "Fresh")],
                                               removed: [.init(id: "new:gone", title: "Gone")])])
        XCTAssertEqual(diff.entries.first { $0.kind == .removed }?.task.title, "Gone", "a removed task keeps what it was")
    }

    /// Encode's graph has nothing before it: every task is new. A task an edge merely names is
    /// the graph's, never added or removed by the plan.
    func testTheFirstGraphIsAllAddedAndExistingTasksAreNeverAddedOrRemoved() {
        let new = TaskGraphModel(changeSet: set([task("t1", "One"), .addEdge(from: .new("t1"), to: .existing("fd-12"), kind: .blocks)]),
                                 graph: graph)
        let first = TaskGraphDiff(old: nil, new: new)
        XCTAssertEqual(first.entries.map(\.id), ["new:t1"])
        XCTAssertEqual(first.added, 1)
        let dropped = TaskGraphModel(changeSet: set([task("t1", "One")]), graph: graph)
        let diff = TaskGraphDiff(old: new, new: dropped)
        XCTAssertEqual(diff.entries.map(\.kind), [.changed], "only t1, which lost the dependency")
        XCTAssertEqual(diff.entries.first?.links.first?.removed.map(\.id), ["fd-12"])
    }

    func testIdenticalGraphsHaveNoChanges() {
        let a = TaskGraphModel(changeSet: set([task("t1", "One"), task("t2", "Two")]), graph: nil)
        let diff = TaskGraphDiff(old: a, new: a)
        XCTAssertTrue(diff.entries.isEmpty)
        XCTAssertEqual(diff.unchanged, 2)
    }

    // MARK: - Word diff

    func testWordDiffMarksOnlyTheWordsThatChanged() {
        XCTAssertEqual(WordDiff.runs("Store the size.", "Store the font size."), [
            .init(text: "Store the ", kind: .same), .init(text: "font ", kind: .added), .init(text: "size.", kind: .same),
        ])
        let runs = WordDiff.runs("a b c", "a x c")
        XCTAssertEqual(runs.filter { $0.kind != .added }.map(\.text).joined(), "a b c", "the old text, back out")
        XCTAssertEqual(runs.filter { $0.kind != .removed }.map(\.text).joined(), "a x c", "the new text, back out")
        XCTAssertEqual(WordDiff.runs("", "new words"), [.init(text: "new words", kind: .added)])
        XCTAssertEqual(WordDiff.runs("old", ""), [.init(text: "old", kind: .removed)])
    }
}
