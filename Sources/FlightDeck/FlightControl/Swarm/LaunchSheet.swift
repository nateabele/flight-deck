import IntakeKit
import SwiftUI

/// Opens the launch sheet for one project: from a released intake (`.intake`) or the project
/// header's menu (`.allReady`).
struct SwarmLaunchRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
    let filter: SwarmFilter
    let title: String
}

@MainActor
final class LaunchSheetModel: ObservableObject {
    enum SourceChip: String, Equatable {
        case rule, index, `default`, spill, manual, pinned
        init(_ kind: AssignmentSourceKind) {
            switch kind {
            case .rule: self = .rule
            case .index: self = .index
            case .default: self = .default
            case .spill: self = .spill
            case .manual: self = .manual
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        var block: ExecutionBlock?
        var chip: SourceChip?
        /// Why this task cannot run, shown greyed. Nil for a routable row.
        var unroutable: String?
        var existingContext: String?
        /// Re-routed here and so written back on Launch, so the controller (which reads blocks
        /// from br) runs exactly what the sheet showed.
        var changed: Bool
        /// The kind the task already carries; an override keeps it.
        var kind: KindID?
        /// False when a newer Flight Deck wrote the block: overriding would overwrite what this build cannot read.
        var canOverride = true

        var summary: String {
            guard let b = block else { return "—" }
            let knobs = ConfigKey.knobsText(b.knobs)
            return [b.harness.rawValue, b.model, knobs.isEmpty ? nil : knobs, b.pool.rawValue].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var cap: Int = 3
    @Published var poolCaps: [String: Int] = [:]

    let request: SwarmLaunchRequest
    private let backend: SwarmBackend
    private let service: SwarmService
    private let registry: RoutingCapabilityRegistry
    private var directory: (any PoolDirectory)?
    /// Set for the whole of `launch()`, so a double press starts one swarm.
    private var launching = false
    private let now: () -> Date
    private var projectURL: URL { URL(fileURLWithPath: request.project, isDirectory: true) }

    init(request: SwarmLaunchRequest, backend: SwarmBackend, service: SwarmService,
         registry: RoutingCapabilityRegistry, now: @escaping () -> Date = Date.init) {
        self.request = request; self.backend = backend; self.service = service; self.registry = registry; self.now = now
    }

    /// The pools the Override picker offers for `harness`; empty means the sheet falls back to free text.
    func poolOptions(for harness: HarnessID) -> [PoolSummary] { directory?.pools().filter { $0.harness == harness } ?? [] }
    func defaultPool(for harness: HarnessID) -> PoolID? { directory?.defaultPool(for: harness) }

    /// The pool to show after the harness changes: its default, else its first listed pool, else
    /// empty (free text). Never the previous harness's pool.
    func pool(afterChangingTo harness: HarnessID) -> String {
        (defaultPool(for: harness) ?? poolOptions(for: harness).first?.id)?.rawValue ?? ""
    }

    /// A listed pool for `harness` when the directory has any; else any non-empty text.
    func isValidPool(_ pool: String, for harness: HarnessID) -> Bool {
        let options = poolOptions(for: harness)
        return options.isEmpty ? !pool.isEmpty : options.contains { $0.id.rawValue == pool }
    }

    var pools: [String] { Set(rows.compactMap { $0.unroutable == nil ? $0.block?.pool.rawValue : nil }).sorted() }
    var canLaunch: Bool { service.dependencies != nil && rows.contains { $0.unroutable == nil } }

    func load() async {
        loading = true
        defer { loading = false }
        guard let deps = service.dependencies else { error = "Flight Control routing is not connected yet."; return }
        let tasks: [ReadyTask]
        switch await backend.readyTasks(project: projectURL) {
        case .success(let ready): tasks = ready; error = nil
        case .failure(let failure): error = failure.message; return
        }
        directory = deps.pools
        let router = deps.makeRouter()
        let kinds = (try? deps.kinds.kinds(project: projectURL)) ?? []
        let catalogs = await (deps.catalogs ?? { await self.registry.catalogs(enabled: Set(self.registry.harnesses)) })()
        rows = tasks.filter { request.filter.admits($0.id) }
            .map { route($0, router: router, kinds: kinds, catalogs: catalogs) }
        // Spec §3: a local pool (every slot has no account) defaults to its own slot count.
        for pool in pools where poolCaps[pool] == nil {
            let slots = deps.capacity.headroom(pool: PoolID(pool))
            if !slots.isEmpty, slots.allSatisfy({ $0.account.id == nil }) { poolCaps[pool] = slots.count }
        }
    }

    private func route(_ task: ReadyTask, router: any Router, kinds: [TaskKind], catalogs: AdapterCatalogs) -> Row {
        var row = Row(id: task.id, title: task.title, block: nil, chip: nil, unroutable: nil,
                      existingContext: task.agentContext, changed: false, kind: nil)
        switch task.block {
        case .failure(let failure):
            row.unroutable = failure.message
            if case .unsupportedVersion = failure { row.canOverride = false }
        case .success(nil):
            row.unroutable = "no execution block"
        case .success(let block?):
            row.kind = block.kind
            if block.pinned {
                row.block = block; row.chip = .pinned
            } else if let kind = KindResolution.resolve(block.kind, in: kinds) {
                let assignment = router.assign(kind: kind, project: projectURL, catalogs: catalogs, now: now())
                if assignment.isUnroutable {
                    row.unroutable = assignment.unroutableReason
                } else {
                    row.block = assignment.block
                    row.chip = SourceChip(assignment.block.source.by)
                    row.changed = !assignment.block.sameRouting(as: block)
                }
            } else {
                row.unroutable = "unknown kind \(block.kind)"
            }
            if let routed = row.block, registry.capabilities(for: routed.harness) == nil {
                row.unroutable = "no adapter named \(routed.harness)"
            }
        }
        return row
    }

    /// Spec §3 "Override": sets `pinned`, writes the block back, keeps the task's kind (a task
    /// with no block yet gets the seed `implement-simple`).
    func override(_ rowID: String, harness: HarnessID, model: String, knobs: [String: String], pool: PoolID) async -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == rowID }), rows[index].canOverride else { return false }
        let block = ExecutionBlock(kind: rows[index].kind ?? "implement-simple", harness: harness, model: model,
                                   knobs: knobs, pool: pool,
                                   source: AssignmentSource(by: .manual, reason: "set in the launch sheet", at: now()),
                                   pinned: true)
        guard await backend.writeBlock(block, task: rowID, existingContext: rows[index].existingContext, project: projectURL) else {
            error = "Could not save the override for \(rowID)."
            return false
        }
        rows[index].existingContext = try? ExecutionBlockCodec.encode(block, into: rows[index].existingContext)
        rows[index].block = block
        rows[index].kind = block.kind
        rows[index].chip = .pinned
        rows[index].changed = false
        rows[index].unroutable = registry.capabilities(for: harness) == nil ? "no adapter named \(harness)" : nil
        return true
    }

    /// A failed write-back aborts: the controller reads blocks from br, so launching anyway would
    /// run a block different from the one this sheet showed.
    func launch() async -> SwarmRecord? {
        guard !launching else { return nil }
        launching = true
        defer { launching = false }
        var failed: [String] = []
        for row in rows where row.changed && row.unroutable == nil {
            guard let block = row.block else { continue }
            if await backend.writeBlock(block, task: row.id, existingContext: row.existingContext, project: projectURL) {
                // Saved: a later Launch must not write it again.
                if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].changed = false }
            } else {
                failed.append(row.id)
            }
        }
        guard failed.isEmpty else {
            error = "Could not save the routing for \(failed.joined(separator: ", "))"
            return nil
        }
        return service.launch(project: request.project, cap: cap, poolCaps: poolCaps, filter: request.filter)
    }

    /// `effort=high, agent=build` → knobs. Nil on a fragment with no `=`.
    static func parseKnobs(_ text: String) -> [String: String]? {
        var knobs: [String: String] = [:]
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            knobs[pair[0]] = pair[1]
        }
        return knobs
    }
}

struct LaunchSheet: View {
    @StateObject var model: LaunchSheetModel
    let harnesses: [HarnessID]
    let onClose: () -> Void
    @State private var editing: String?
    @State private var draftHarness: HarnessID = "claude"
    @State private var draftModel = ""
    @State private var draftKnobs = ""
    @State private var draftPool = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run tasks — \(model.request.title)").font(.headline)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            List(model.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.id) · \(row.title)")
                        Text(row.unroutable.map { "unroutable: \($0)" } ?? "\(row.block?.kind.rawValue ?? "—") · \(row.summary)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let chip = row.chip { Text(chip.rawValue).font(.caption2).padding(.horizontal, 6).background(Capsule().fill(.quaternary)) }
                    Button("Override…") {
                        editing = row.id
                        draftHarness = row.block?.harness ?? "claude"
                        draftModel = row.block?.model ?? ""
                        draftKnobs = row.block.map { ConfigKey.knobsText($0.knobs) } ?? ""
                        draftPool = row.block?.pool.rawValue ?? model.defaultPool(for: draftHarness)?.rawValue ?? ""
                    }
                    .disabled(!row.canOverride)
                    .accessibilityIdentifier("launch-override-\(row.id)")
                }
                .opacity(row.unroutable == nil ? 1 : 0.45)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("launch-row-\(row.id)")
            }
            .frame(minHeight: 220)
            if let id = editing { overrideEditor(id) }
            HStack {
                Stepper("Agents at once: \(model.cap)", value: $model.cap, in: 1...16)
                    .accessibilityIdentifier("launch-cap")
                ForEach(model.pools, id: \.self) { pool in
                    Stepper("\(pool): \(model.poolCaps[pool].map(String.init) ?? "—")",
                            value: Binding(get: { model.poolCaps[pool] ?? model.cap },
                                           set: { model.poolCaps[pool] = $0 }), in: 1...16)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).accessibilityIdentifier("launch-cancel")
                Button("Launch") { Task { if await model.launch() != nil { onClose() } } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canLaunch)
                    .accessibilityIdentifier("launch-swarm")
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 420)
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swarm-launch-sheet")
    }

    private func overrideEditor(_ id: String) -> some View {
        HStack {
            Picker("Agent", selection: $draftHarness) {
                ForEach(harnesses, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 140)
            .onChange(of: draftHarness) { harness in
                draftPool = model.pool(afterChangingTo: harness)
            }
            TextField("Model", text: $draftModel).frame(width: 140)
            TextField("Knobs, e.g. effort=high", text: $draftKnobs).frame(width: 180)
            let options = model.poolOptions(for: draftHarness)
            if options.isEmpty {
                TextField("Pool", text: $draftPool).frame(width: 140)
            } else {
                Picker("Pool", selection: $draftPool) {
                    ForEach(options, id: \.id) { Text($0.label).tag($0.id.rawValue) }
                }.frame(width: 180)
            }
            Button("Save") {
                guard let knobs = LaunchSheetModel.parseKnobs(draftKnobs), !draftModel.isEmpty,
                      model.isValidPool(draftPool, for: draftHarness) else { return }
                Task { if await model.override(id, harness: draftHarness, model: draftModel, knobs: knobs, pool: PoolID(draftPool)) { editing = nil } }
            }
            .disabled(!model.isValidPool(draftPool, for: draftHarness))
            Button("Close") { editing = nil }
        }
        .font(.caption)
    }
}

private extension ExecutionBlock {
    /// What a router decides, without the timestamp and prose it stamps on every answer: comparing
    /// those would make every unpinned row look changed, and rewrite it, on every Launch.
    func sameRouting(as other: ExecutionBlock) -> Bool {
        kind == other.kind && harness == other.harness && model == other.model && knobs == other.knobs
            && pool == other.pool && source.by == other.source.by && source.ruleId == other.source.ruleId
    }
}
