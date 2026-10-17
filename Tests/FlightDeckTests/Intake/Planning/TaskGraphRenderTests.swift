import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The plan area's Task Graph and Task Changes tabs, for design review — skipped unless
/// `FD_PLANNING_RENDER_DIR` names an output directory. Pictures, not assertions.
@MainActor
final class TaskGraphRenderTests: XCTestCase {
    private let pre = Precondition(status: "open", assignee: nil)
    private let graph = GraphSnapshot(beads: [
        "fd-12": BeadSnapshot(id: "fd-12", title: "Settings window", status: "in_progress"),
        "fd-9": BeadSnapshot(id: "fd-9", title: "Font at surface init", status: "open"),
    ])

    private func task(_ t: String, _ title: String, _ description: String, _ acceptance: String, priority: Int = 2) -> ChangeOp {
        .createBead(NewBead(tempId: t, title: title, priority: priority, description: description, acceptance: acceptance,
                            labels: ["prefs"], taskKind: "storage"))
    }

    private var before: ChangeSet {
        ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 0), ops: [
            task("store", "Store font size per project",
                 "Persist the chosen font size in the project's settings file so it survives a relaunch.",
                 "Unit: the size round-trips through the settings file. End-to-end: relaunch keeps it."),
            task("apply", "Apply the project's font size to new tabs",
                 "When a tab opens in a project, read its font size and hand it to the terminal surface.",
                 "Unit: a new tab gets the project's size."),
            task("menu", "Font size menu items", "Bigger, Smaller and Reset in the View menu.", "UI: each item changes the size."),
            .addEdge(from: .new("apply"), to: .new("store"), kind: .blocks),
            .addEdge(from: .new("store"), to: .existing("fd-12"), kind: .blocks),
            .addEdge(from: .new("menu"), to: .new("apply"), kind: .blocks),
        ])
    }

    private var after: ChangeSet {
        ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 0), ops: [
            task("store", "Store font size per project",
                 "Persist the chosen font size in the project's own settings file so it survives a relaunch and a sync.",
                 "Unit: the size round-trips through the settings file. End-to-end: relaunch keeps it.", priority: 1),
            task("apply", "Apply the project's font size to new tabs",
                 "When a tab opens in a project, read its font size and hand it to the terminal surface.",
                 "Unit: a new tab gets the project's size."),
            task("migrate", "Migrate the global font size", "Copy the old global setting into every project once.",
                 "Unit: a project with no size gets the global one."),
            .addEdge(from: .new("apply"), to: .new("store"), kind: .blocks),
            .addEdge(from: .new("store"), to: .existing("fd-12"), kind: .blocks),
            .addEdge(from: .new("apply"), to: .new("migrate"), kind: .blocks),
            .editBead(id: "fd-9", set: FieldSet(title: "Resolve font at surface init", priority: 1), pre: pre, delivery: nil),
        ])
    }

    func testRenderTaskGraphAndTaskChanges() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let old = TaskGraphModel(changeSet: before, graph: graph), new = TaskGraphModel(changeSet: after, graph: graph)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try PlanningRender.write(ScrollView { TaskGraphView(model: new) }.background(Color(nsColor: .windowBackgroundColor)),
                                     size: NSSize(width: 720, height: 1300),
                                     to: out.appendingPathComponent("task-graph-\(suffix).png"), appearance: appearance)
            try PlanningRender.write(ScrollView { TaskChangesView(diff: TaskGraphDiff(old: old, new: new)) }
                                        .background(Color(nsColor: .windowBackgroundColor)),
                                     size: NSSize(width: 720, height: 1100),
                                     to: out.appendingPathComponent("task-changes-\(suffix).png"), appearance: appearance)
        }
    }
}
