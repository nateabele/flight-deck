import Foundation
import IntakeKit

/// A checkpoint's change set read as tasks: every task it creates, follows up, edits or
/// reopens, with all of its fields and its dependencies both ways — what the plan area's Task
/// Graph tab draws. The change set itself is a list of ops (a task, then an edge, then an
/// edit), which said nothing about a task's dependencies where the task was, and the list
/// that showed it gave each task one line, title only.
///
/// Existing tasks the change set only names in an edge are here too (`.existing`), titled
/// from the checkpoint's `graph.json`, so a dependency on one reads as a task, not an id.
struct TaskGraphModel: Equatable {
    enum Origin: Equatable {
        case new
        case followUp(of: String)
        case edit
        case reopen
        /// Named by an edge only; its fields are the live graph's, not the plan's.
        case existing
    }

    struct Link: Equatable, Hashable {
        var id: String
        var title: String
    }

    struct Task: Equatable, Identifiable {
        /// The id an edge uses: `new:<tempId>` for a task this plan creates, the graph's id
        /// for an existing one.
        var id: String
        var origin: Origin
        var title: String
        var type: String?
        var priority: Int?
        var labels: [String] = []
        var taskKind: String?
        var description: String?
        var acceptance: String?
        /// An existing task's status in the graph the change set was checked against.
        var status: String?
        /// What an `editTask` sets.
        var edits: FieldSet?
        var delivery: Delivery?
        /// A reopen's reason.
        var reason: String?
        /// `blocks` edges from this task: what it waits on.
        var dependsOn: [Link] = []
        /// `blocks` edges to this task: what waits on it.
        var neededBy: [Link] = []
        /// `parent-child` edges from this task (it is the child).
        var parents: [Link] = []
        var children: [Link] = []
        /// `related` edges this task names, and the ones naming it.
        var relatedTo: [Link] = []
        var relatedFrom: [Link] = []
    }

    var tasks: [Task]
    var edgeCount: Int

    var newCount: Int { tasks.filter { if case .new = $0.origin { true } else if case .followUp = $0.origin { true } else { false } }.count }
    var existingChangedCount: Int { tasks.filter { $0.origin == .edit || $0.origin == .reopen }.count }

    init(changeSet: ChangeSet, graph: GraphSnapshot?) {
        var order: [String] = []
        var byID: [String: Task] = [:]
        func existingTitle(_ id: String) -> String { graph?.beads[id]?.title ?? id }
        func upsert(_ id: String, _ make: () -> Task, _ change: (inout Task) -> Void = { _ in }) {
            if byID[id] == nil {
                order.append(id)
                byID[id] = make()
            }
            change(&byID[id]!)
        }
        func existing(_ id: String) -> Task {
            Task(id: id, origin: .existing, title: existingTitle(id), labels: graph?.beads[id]?.labels ?? [],
                 status: graph?.beads[id]?.status)
        }

        var edges: [(from: String, to: String, kind: EdgeKind)] = []
        for op in changeSet.ops {
            switch op {
            case .createBead(let b):
                upsert("new:\(b.tempId)", {
                    Task(id: "new:\(b.tempId)", origin: .new, title: b.title, type: b.type, priority: b.priority, labels: b.labels,
                         taskKind: b.kindProposal?.name ?? b.taskKind?.rawValue, description: b.description, acceptance: b.acceptance)
                })
            case .followUp(let tempId, let of, let title, let description, _):
                upsert("new:\(tempId)", {
                    Task(id: "new:\(tempId)", origin: .followUp(of: of), title: title, description: description)
                })
            case .editBead(let id, let set, _, let delivery):
                upsert(id, { existing(id) }) {
                    if $0.origin == .existing { $0.origin = .edit }
                    $0.edits = set
                    $0.delivery = delivery
                }
            case .reopen(let id, let reason, _):
                upsert(id, { existing(id) }) {
                    if $0.origin == .existing { $0.origin = .reopen }
                    $0.reason = reason
                }
            case .addEdge(let from, let to, let kind):
                edges.append((from.wireValue, to.wireValue, kind))
            }
        }
        // A follow-up is related to the closed task it follows, which the release writes as
        // an edge of its own; drawn here, so the task it continues is one click from it.
        for id in order {
            if case .followUp(let of)? = byID[id]?.origin { edges.append((id, of, .related)) }
        }
        for edge in edges {
            for id in [edge.from, edge.to] where byID[id] == nil {
                // A `new:` id nothing creates fails validation; drawn anyway, by its id.
                upsert(id, { id.hasPrefix("new:") ? Task(id: id, origin: .new, title: id) : existing(id) })
            }
            let from = Link(id: edge.from, title: byID[edge.from]!.title)
            let to = Link(id: edge.to, title: byID[edge.to]!.title)
            switch edge.kind {
            case .blocks:
                byID[edge.from]!.dependsOn.append(to)
                byID[edge.to]!.neededBy.append(from)
            case .parentChild:
                byID[edge.from]!.parents.append(to)
                byID[edge.to]!.children.append(from)
            case .related:
                byID[edge.from]!.relatedTo.append(to)
                byID[edge.to]!.relatedFrom.append(from)
            }
        }
        tasks = Self.dependencyOrder(order.map { byID[$0]! })
        edgeCount = edges.count
    }

    /// Each task after everything it depends on, otherwise in the change set's order — so the
    /// page reads in the order the work can be done. A cycle (which validation refuses) keeps
    /// its tasks in change-set order rather than dropping them.
    static func dependencyOrder(_ tasks: [Task]) -> [Task] {
        let ids = Set(tasks.map(\.id))
        var placed = Set<String>()
        var out: [Task] = []
        var rest = tasks
        while !rest.isEmpty {
            let ready = rest.firstIndex { $0.dependsOn.allSatisfy { placed.contains($0.id) || !ids.contains($0.id) } } ?? 0
            let task = rest.remove(at: ready)
            placed.insert(task.id)
            out.append(task)
        }
        return out
    }

    /// The checkpoint's task graph: its change set, titled from the graph it was checked
    /// against. Nil when the checkpoint has no change set (a round before Encode).
    static func load(checkpoint: Int, loadFile: (Int, String) -> Data?) -> Result<TaskGraphModel, LoadFailure>? {
        guard let data = loadFile(checkpoint, "changeset.json") else { return nil }
        guard let set = try? ChangeSet.decode(data) else { return .failure(.unreadable) }
        let graph = loadFile(checkpoint, "graph.json").flatMap { try? IntakeJSON.decoder.decode(GraphSnapshot.self, from: $0) }
        return .success(TaskGraphModel(changeSet: set, graph: graph))
    }

    enum LoadFailure: Error, Equatable { case unreadable }

    /// The newest checkpoint up to `checkpoint` (in tape order) that has a change set — what a
    /// view following the head shows, the way the plan follows the newest plan.
    static func latestWithChangeSet(upTo checkpoint: Int, tape: Tape, loadFile: (Int, String) -> Data?) -> Int? {
        guard let end = tape.checkpoints.firstIndex(where: { $0.id == checkpoint }) else { return nil }
        return tape.checkpoints[...end].reversed().first { loadFile($0.id, "changeset.json") != nil }?.id
    }

    /// The checkpoint before `checkpoint` that has a change set — what Task Changes compares to.
    static func previousWithChangeSet(before checkpoint: Int, tape: Tape, loadFile: (Int, String) -> Data?) -> Int? {
        guard let end = tape.checkpoints.firstIndex(where: { $0.id == checkpoint }), end > 0 else { return nil }
        return tape.checkpoints[..<end].reversed().first { loadFile($0.id, "changeset.json") != nil }?.id
    }
}

/// One round's task changes against the round before it: the tasks it added and removed, and
/// for each task it changed, which fields and dependencies — what the Task Changes tab colours.
struct TaskGraphDiff: Equatable {
    enum Kind: Equatable { case added, removed, changed }

    struct FieldChange: Equatable {
        var field: String
        var old: String?
        var new: String?
    }

    /// Dependencies are compared on the side that names them (the edge's `from`), so an edge
    /// is one change, not one on each task it joins.
    struct LinkChange: Equatable {
        var relation: String
        var added: [TaskGraphModel.Link]
        var removed: [TaskGraphModel.Link]
    }

    struct Entry: Equatable, Identifiable {
        var id: String { task.id }
        var kind: Kind
        /// The task as it is now; as it was, for a removed one.
        var task: TaskGraphModel.Task
        var fields: [FieldChange] = []
        var links: [LinkChange] = []
    }

    var entries: [Entry]
    var unchanged: Int

    var added: Int { entries.filter { $0.kind == .added }.count }
    var removed: Int { entries.filter { $0.kind == .removed }.count }
    var changed: Int { entries.filter { $0.kind == .changed }.count }

    /// `old` nil: the first task graph (Encode's), every task added. Tasks an edge merely
    /// names (`.existing`) are never added or removed — the plan didn't make them — but a
    /// dependency one of them gained or lost is still a change.
    init(old: TaskGraphModel?, new: TaskGraphModel) {
        let before = Dictionary((old?.tasks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Set(new.tasks.map(\.id))
        var entries: [Entry] = []
        var unchanged = 0
        for task in new.tasks {
            guard let was = before[task.id] else {
                if task.origin != .existing { entries.append(Entry(kind: .added, task: task)) }
                continue
            }
            let fields = Self.fieldChanges(was, task), links = Self.linkChanges(was, task)
            if fields.isEmpty && links.isEmpty {
                if task.origin != .existing { unchanged += 1 }
            } else {
                entries.append(Entry(kind: .changed, task: task, fields: fields, links: links))
            }
        }
        for task in old?.tasks ?? [] where !now.contains(task.id) && task.origin != .existing {
            entries.append(Entry(kind: .removed, task: task))
        }
        self.entries = entries
        self.unchanged = unchanged
    }

    static func fieldChanges(_ a: TaskGraphModel.Task, _ b: TaskGraphModel.Task) -> [FieldChange] {
        var out: [FieldChange] = []
        func check(_ field: String, _ x: String?, _ y: String?) {
            let x = x.flatMap { $0.isEmpty ? nil : $0 }, y = y.flatMap { $0.isEmpty ? nil : $0 }
            if x != y { out.append(FieldChange(field: field, old: x, new: y)) }
        }
        check("Title", a.title, b.title)
        check("Kind of change", origin(a.origin), origin(b.origin))
        check("Type", a.type, b.type)
        check("Priority", a.priority.map { "P\($0)" }, b.priority.map { "P\($0)" })
        check("Labels", a.labels.joined(separator: ", "), b.labels.joined(separator: ", "))
        check("Task kind", a.taskKind, b.taskKind)
        check("Description", a.description, b.description)
        check("Acceptance", a.acceptance, b.acceptance)
        check("New title", a.edits?.title, b.edits?.title)
        check("New description", a.edits?.description, b.edits?.description)
        check("New acceptance", a.edits?.acceptance, b.edits?.acceptance)
        check("New priority", a.edits?.priority.map { "P\($0)" }, b.edits?.priority.map { "P\($0)" })
        check("Delivery", a.delivery.map(delivery), b.delivery.map(delivery))
        check("Reopen reason", a.reason, b.reason)
        return out
    }

    static func linkChanges(_ a: TaskGraphModel.Task, _ b: TaskGraphModel.Task) -> [LinkChange] {
        [("Depends on", \TaskGraphModel.Task.dependsOn), ("Child of", \.parents), ("Related to", \.relatedTo)].compactMap { name, path in
            let x = a[keyPath: path], y = b[keyPath: path]
            let xs = Set(x.map(\.id)), ys = Set(y.map(\.id))
            let added = y.filter { !xs.contains($0.id) }, removed = x.filter { !ys.contains($0.id) }
            return added.isEmpty && removed.isEmpty ? nil : LinkChange(relation: name, added: added, removed: removed)
        }
    }

    static func origin(_ o: TaskGraphModel.Origin) -> String {
        switch o {
        case .new: "New task"
        case .followUp(let of): "Follow-up on \(of)"
        case .edit: "Edit to an existing task"
        case .reopen: "Reopen"
        case .existing: "Existing task"
        }
    }

    static func delivery(_ d: Delivery) -> String {
        let rating = switch d.rating {
        case .clarifying: "Clarifying"
        case .scopeChange: "Scope change"
        case .invalidating: "Invalidating"
        }
        return "\(rating): \(d.reason)"
    }
}

/// Word by word, what was kept, dropped and added between two versions of a field — so a
/// changed description shows its two new words in place, not two whole paragraphs to compare.
enum WordDiff {
    enum Kind: Equatable { case same, removed, added }
    struct Run: Equatable { var text: String; var kind: Kind }

    static func runs(_ old: String, _ new: String) -> [Run] {
        let a = tokens(old), b = tokens(new)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Run] = []
        func emit(_ text: String, _ kind: Kind) {
            if let last = out.last, last.kind == kind { out[out.count - 1].text += text } else { out.append(Run(text: text, kind: kind)) }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { emit(a[i], .removed); i += 1 }
            else if j < b.count, inserted.contains(j) { emit(b[j], .added); j += 1 }
            else if i < a.count, j < b.count { emit(b[j], .same); i += 1; j += 1 }
            else if i < a.count { emit(a[i], .removed); i += 1 }
            else { emit(b[j], .added); j += 1 }
        }
        return out
    }

    /// Words with the whitespace after each, so joining the runs gives the text back.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], current = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace { inSpace = true; current.append(ch) }
            else {
                if inSpace { out.append(current); current = ""; inSpace = false }
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
