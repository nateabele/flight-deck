import IntakeKit
import SwiftUI

/// The colours Task Changes marks a task with. Green and red are the plan editor's additions
/// and removals; changed is orange, the round-changed colour the board uses for an exception.
enum TaskChangeTone {
    static let added = Color.green
    static let removed = Color.red
    static let changed = Color.orange

    static func color(_ kind: TaskGraphDiff.Kind) -> Color {
        switch kind {
        case .added: added
        case .removed: removed
        case .changed: changed
        }
    }

    static func word(_ kind: TaskGraphDiff.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .removed: "Removed"
        case .changed: "Changed"
        }
    }
}

/// Every task in the checkpoint's change set, in full, each after what it depends on.
struct TaskGraphView: View {
    let model: TaskGraphModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text(Self.summary(model))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if model.tasks.isEmpty {
                Text("The task graph is empty.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.tasks) { task in
                TaskCard(task: task)
            }
        }
        .padding(10)
        .accessibilityIdentifier("task-graph")
    }

    /// "95 new tasks · 3 edits to existing tasks · 290 dependencies", in dependency order.
    static func summary(_ model: TaskGraphModel) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts = [count(model.newCount, "new task", "new tasks")]
        if model.existingChangedCount > 0 {
            parts.append(count(model.existingChangedCount, "change to an existing task", "changes to existing tasks"))
        }
        parts.append(count(model.edgeCount, "dependency", "dependencies"))
        return parts.joined(separator: " · ") + ", each task after what it depends on"
    }
}

/// One task with everything the change set says about it.
struct TaskCard: View {
    let task: TaskGraphModel.Task
    /// Task Changes' mark: a coloured edge and a word ("Added", "Removed").
    var change: TaskGraphDiff.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let description = task.description, !description.isEmpty {
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let acceptance = task.acceptance, !acceptance.isEmpty {
                section("Acceptance") { Text(acceptance).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            if let edits = task.edits, !edits.isEmpty {
                section("Changes to this task") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.editLines(edits), id: \.0) { label, value in
                            fieldLine(label, value)
                        }
                    }
                }
            }
            if let delivery = task.delivery { fieldLine("Delivery", TaskGraphDiff.delivery(delivery)) }
            if let reason = task.reason { fieldLine("Reopened because", reason) }
            links
        }
        .textSelection(.enabled)
        // A removed task stays readable — it is what the round dropped — with its title struck.
        .opacity(change == .removed ? 0.8 : 1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let change { TaskBadge(text: TaskChangeTone.word(change), color: TaskChangeTone.color(change)) }
                TaskBadge(text: Self.originWord(task.origin), color: .secondary)
                Text(task.title).font(.headline).strikethrough(change == .removed)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(task.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                ForEach(Self.facts(task), id: \.self) { fact in
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(fact).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var links: some View {
        let groups = Self.linkGroups(task).filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.0) { relation, items in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(relation).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(items, id: \.id) { TaskLinkText(link: $0) }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return shape.fill(Color.primary.opacity(0.035))
            .overlay(shape.strokeBorder(change.map { TaskChangeTone.color($0).opacity(0.55) } ?? Color.primary.opacity(0.08),
                                        lineWidth: change == nil ? 0.5 : 1))
            .overlay(alignment: .leading) {
                if let change { UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(TaskChangeTone.color(change)).frame(width: 4) }
            }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func fieldLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func originWord(_ origin: TaskGraphModel.Origin) -> String {
        switch origin {
        case .new: "New"
        case .followUp(let of): "Follow-up on \(of)"
        case .edit: "Edit"
        case .reopen: "Reopen"
        case .existing: "Existing"
        }
    }

    /// "P1 · task · storage · labels: ui, prefs" — the short fields, after the id.
    static func facts(_ task: TaskGraphModel.Task) -> [String] {
        var out: [String] = []
        if let status = task.status { out.append(status.replacingOccurrences(of: "_", with: " ")) }
        if let priority = task.priority { out.append("P\(priority)") }
        if let type = task.type { out.append(type) }
        if let kind = task.taskKind { out.append(kind) }
        if !task.labels.isEmpty { out.append("labels: " + task.labels.joined(separator: ", ")) }
        return out
    }

    static func editLines(_ set: FieldSet) -> [(String, String)] {
        var out: [(String, String)] = []
        if let title = set.title { out.append(("Title", title)) }
        if let priority = set.priority { out.append(("Priority", "P\(priority)")) }
        if let description = set.description { out.append(("Description", description)) }
        if let acceptance = set.acceptance { out.append(("Acceptance", acceptance)) }
        return out
    }

    static func linkGroups(_ task: TaskGraphModel.Task) -> [(String, [TaskGraphModel.Link])] {
        [("Depends on", task.dependsOn), ("Needed by", task.neededBy), ("Child of", task.parents),
         ("Parent of", task.children), ("Related to", task.relatedTo + task.relatedFrom)]
    }
}

struct TaskBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// "Store font size per project  new:t3".
struct TaskLinkText: View {
    let link: TaskGraphModel.Link
    var tint: Color?
    var struck = false

    var body: some View {
        (Text(link.title).font(.callout) + Text("  " + link.id).font(.caption.monospaced()).foregroundColor(.secondary))
            .strikethrough(struck)
            .foregroundStyle(tint ?? .primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The round's tasks against the round before: added and removed tasks in full, changed ones
/// with what changed marked word by word, and the count of the rest.
struct TaskChangesView: View {
    let diff: TaskGraphDiff

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            summary
            if diff.entries.isEmpty {
                Text("No task changed in this round.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(diff.entries) { entry in
                switch entry.kind {
                case .added, .removed: TaskCard(task: entry.task, change: entry.kind)
                case .changed: ChangedTaskCard(entry: entry)
                }
            }
            if diff.unchanged > 0, !diff.entries.isEmpty {
                Text("\(diff.unchanged) unchanged \(diff.unchanged == 1 ? "task isn't" : "tasks aren't") shown.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .accessibilityIdentifier("task-changes")
    }

    private var summary: some View {
        HStack(spacing: 12) {
            count(diff.added, "added", .added)
            count(diff.removed, "removed", .removed)
            count(diff.changed, "changed", .changed)
            Text("\(diff.unchanged) unchanged").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private func count(_ n: Int, _ word: String, _ kind: TaskGraphDiff.Kind) -> some View {
        HStack(spacing: 5) {
            Circle().fill(TaskChangeTone.color(kind)).frame(width: 8, height: 8)
            Text("\(n) \(word)").font(.callout)
        }
    }
}

/// A changed task: its title and id, then each changed field old against new, word by word,
/// and each dependency it gained or lost.
struct ChangedTaskCard: View {
    let entry: TaskGraphDiff.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TaskBadge(text: "Changed", color: TaskChangeTone.changed)
                TaskBadge(text: TaskCard.originWord(entry.task.origin), color: .secondary)
                Text(entry.task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(entry.task.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            ForEach(entry.fields, id: \.field) { change in
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.field.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(Self.marked(old: change.old, new: change.new))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(entry.links, id: \.relation) { change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(change.relation).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(change.added, id: \.id) { link in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("+").font(.callout.monospaced()).foregroundStyle(TaskChangeTone.added)
                                TaskLinkText(link: link, tint: TaskChangeTone.added)
                            }
                        }
                        ForEach(change.removed, id: \.id) { link in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("−").font(.callout.monospaced()).foregroundStyle(TaskChangeTone.removed)
                                TaskLinkText(link: link, tint: TaskChangeTone.removed, struck: true)
                            }
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8)
            shape.fill(Color.primary.opacity(0.035))
                .overlay(shape.strokeBorder(TaskChangeTone.changed.opacity(0.55), lineWidth: 1))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(TaskChangeTone.changed).frame(width: 4)
                }
        }
        .accessibilityElement(children: .combine)
    }

    /// Old and new in one run of text: kept words plain, dropped ones struck through in red,
    /// added ones on green — the plan diff's marks, for a field.
    static func marked(old: String?, new: String?) -> AttributedString {
        var out = AttributedString()
        let runs = WordDiff.runs(old ?? "", new ?? "")
        for (i, run) in runs.enumerated() {
            // "P2 P1", not "P2P1": a replaced last word has no space of its own before its successor.
            let spaced = run.kind == .removed && i + 1 < runs.count && runs[i + 1].kind == .added
                && !(run.text.last?.isWhitespace ?? true)
            var piece = AttributedString(spaced ? run.text + " " : run.text)
            switch run.kind {
            case .same: break
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = TaskChangeTone.removed
                piece.backgroundColor = TaskChangeTone.removed.opacity(0.12)
            case .added:
                piece.foregroundColor = Color.primary
                piece.backgroundColor = TaskChangeTone.added.opacity(0.22)
            }
            out += piece
        }
        return out
    }
}
