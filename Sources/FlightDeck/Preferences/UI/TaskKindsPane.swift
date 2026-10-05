import IntakeKit
import SwiftUI

/// Settings → Flight Control → Task kinds (spec L3-R §6), per project: each kind's origin,
/// status, weights as small bars and open-task count, with Rename, Re-weight and Merge into….
/// A planning-proposed kind is marked *new* until you open it. Re-weight and merge re-route the
/// kind's open, unpinned tasks; the summary shows under the list.
struct TaskKindsPane: View {
    @ObservedObject var routing: RoutingService
    let project: String?
    @State private var selection: KindID?
    @State private var renameText = ""
    @State private var weights: [String: Double] = [:]
    @State private var mergeTarget: KindID?
    @State private var counts: [KindID: Int] = [:]
    @State private var error: String?

    var body: some View {
        if let project {
            content(project)
        } else {
            ContentUnavailableView("No Project Selected", systemImage: "folder",
                                   description: Text("Pick a project to see its task kinds."))
        }
    }

    @ViewBuilder
    private func content(_ project: String) -> some View {
        switch routing.kinds(project: project) {
        case .unreadable(let why):
            Text(why)
                .foregroundStyle(.red)
                .padding(16)
                .accessibilityIdentifier("kinds-error")
        case .loaded(let kinds):
            VStack(alignment: .leading, spacing: 0) {
                HSplitView {
                    List(kinds, selection: $selection) { kind in
                        row(KindRowPresentation(kind: kind, isNew: routing.isNew(kind, project: project),
                                                openCount: counts[kind.id] ?? 0))
                    }
                    .frame(minWidth: 300, idealWidth: 340)
                    detail(kinds, project: project)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                footer
            }
            .onChange(of: selection) { _, new in
                guard let new, let kind = kinds.first(where: { $0.id == new }) else { return }
                routing.markSeen(new, project: project)
                renameText = kind.name
                weights = kind.dimensions
                mergeTarget = nil
                error = nil
            }
            .task(id: project) { counts = await routing.openCounts(project: project) }
        }
    }

    private func row(_ p: KindRowPresentation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name)
                    if p.isNew {
                        Text("new")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .accessibilityIdentifier("kind-new-\(p.id)")
                    }
                }
                Text("\(p.id) · \(p.originLabel) · \(p.statusLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("kind-status-\(p.id)")
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(p.bars, id: \.dimension) { bar in
                    Capsule()
                        .fill(Color.accentColor.opacity(bar.weight > 0 ? 0.75 : 0.15))
                        .frame(width: 4, height: max(2, 18 * bar.weight))
                        .help("\(bar.dimension) \(RuleText.number(bar.weight))")
                }
            }
            .frame(height: 18, alignment: .bottom)
            .accessibilityHidden(true)
            Text("\(p.openCount) open")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("kind-count-\(p.id)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detail(_ kinds: [TaskKind], project: String) -> some View {
        if let id = selection, let kind = kinds.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind.name).font(.headline)
                    Text(kind.description).font(.callout).foregroundStyle(.secondary)
                    GroupBox("Rename") {
                        HStack {
                            TextField("Name", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("kind-rename-field")
                            Button("Rename") { error = routing.rename(kind.id, to: renameText, project: project) }
                                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText == kind.name)
                                .accessibilityIdentifier("kind-rename-apply")
                        }
                    }
                    GroupBox("Re-weight") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Dimensions.all, id: \.id) { d in
                                HStack {
                                    Text(d.id).font(.caption).frame(width: 170, alignment: .leading)
                                    Slider(value: weight(d.id), in: 0...1, step: 0.05)
                                        .accessibilityIdentifier("kind-weight-\(d.id)")
                                    Text(RuleText.number(weights[d.id] ?? 0))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                            Button("Re-weight") {
                                let next = weights.filter { $0.value > 0 }
                                Task {
                                    error = await routing.reweight(kind.id, dimensions: next, project: project)
                                    counts = await routing.openCounts(project: project)
                                }
                            }
                            .disabled(weights.filter { $0.value > 0 } == kind.dimensions)
                            .accessibilityIdentifier("kind-reweight-apply")
                        }
                    }
                    GroupBox("Merge into…") {
                        HStack {
                            Picker("Merge into", selection: $mergeTarget) {
                                Text("Choose…").tag(KindID?.none)
                                ForEach(KindRowPresentation.mergeTargets(for: kind, in: kinds)) { target in
                                    Text(target.name).tag(KindID?.some(target.id))
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("kind-merge-picker")
                            Button("Merge") {
                                guard let target = mergeTarget else { return }
                                Task {
                                    error = await routing.merge(kind.id, into: target, project: project)
                                    mergeTarget = nil
                                    // A merged kind must not keep offering Rename/Re-weight/Merge.
                                    if error == nil { selection = nil }
                                    counts = await routing.openCounts(project: project)
                                }
                            }
                            .disabled(mergeTarget == nil)
                            .accessibilityIdentifier("kind-merge-apply")
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text("Select a kind to rename, re-weight or merge it.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("kind-error")
            }
            if let note = routing.kindNote {
                Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("kind-note")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func weight(_ dimension: String) -> Binding<Double> {
        Binding(get: { weights[dimension] ?? 0 }, set: { weights[dimension] = $0 })
    }
}
