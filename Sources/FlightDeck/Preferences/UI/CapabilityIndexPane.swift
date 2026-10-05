import IntakeKit
import SwiftUI

/// Settings → Capability index (spec §8): the heatmap (color is the score,
/// strength is the confidence), click-through to the cited rows, the diff with Roll back, the
/// sources, the alias table with pending proposals, hand-entered scores and the refresh agent.
///
/// Times are shown in UTC on purpose: snapshot names are UTC, and a screenshot or a bug report
/// should name the same snapshot whatever zone it was taken in.
struct CapabilityIndexPane: View {
    @ObservedObject var service: CapabilityIndexService
    @State private var selectedCell: CellSelection?
    @State private var editing: ManualDraft?

    struct CellSelection: Identifiable {
        let model: ModelRef
        let dimension: String
        var id: String { CapabilityIndexPane.cellIdentifier(model: model, dimension: dimension) }
    }

    struct ManualDraft: Identifiable {
        let id = UUID()
        var entry: ManualModelScores
        var original: ModelRef?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let problem = service.problem {
                    Text(problem).foregroundStyle(.red).accessibilityIdentifier("index-problem")
                }
                heatmap
                diff
                sourcesSection
                aliasesSection
                manualSection
                agentSection
                logSection
            }
            .padding(20)
        }
        .sheet(item: $selectedCell) { cell in citationsSheet(cell) }
        .sheet(item: $editing) { draft in
            ManualScoresEditor(entry: draft.entry, knownModels: knownModels) { saved in
                service.setManual(saved, replacing: draft.original)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capability index").font(.title3.bold())
                Text(snapshotLine)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("index-last-refresh")
            }
            Spacer()
            Button(service.isRefreshing ? "Refreshing…" : "Refresh now") { service.startRefresh() }
                .disabled(service.isRefreshing)
                .accessibilityIdentifier("index-refresh-now")
            Button("Roll back") { service.rollBack() }
                .disabled(!service.canRollBack || service.isRefreshing)
                .help("Make the previous snapshot current")
                .accessibilityIdentifier("index-rollback")
        }
    }

    private var snapshotLine: String {
        guard let current = service.current else {
            return "No snapshot yet. Refresh now reads every enabled source; after that the index refreshes weekly."
        }
        let attempt = service.config.lastRefreshAttemptAt.map { " · last attempt \(Self.utc($0))" } ?? ""
        return "Current snapshot \(Self.utc(current.createdAt))\(attempt)"
    }

    // MARK: Heatmap

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scores").font(.headline)
            if service.scores.isEmpty {
                Text("No model has a score yet.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 2) {
                        GridRow {
                            Text("Model").font(.caption.bold())
                            ForEach(Dimensions.all, id: \.id) { d in
                                Text(Self.shortName(d.id)).font(.caption2).frame(width: 52).help(d.summary)
                            }
                        }
                        ForEach(service.scores, id: \.model) { row in
                            GridRow {
                                Text(IndexKeys.label(row.model)).font(.caption).lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                ForEach(Dimensions.all, id: \.id) { d in
                                    cell(row.model, d.id, row.dimensions[d.id])
                                }
                            }
                        }
                    }
                }
            }
            Text("Color is the score; strength is the confidence. M is entered by hand, I is inherited. Click a cell to see the rows behind it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("index-heatmap")
    }

    private func cell(_ model: ModelRef, _ dimension: String, _ score: DimensionScore?) -> some View {
        Button {
            selectedCell = CellSelection(model: model, dimension: dimension)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(score.map { Self.color(for: $0.score).opacity(Self.cellOpacity(confidence: $0.confidence)) }
                          ?? Color.secondary.opacity(0.08))
                Text(score.map { String(format: "%.2f", $0.score) + Self.originMark($0.origin) } ?? "—")
                    .font(.caption2.monospacedDigit())
            }
            .frame(width: 52, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(score == nil)
        .accessibilityLabel(Self.cellValue(score))
        .accessibilityIdentifier(Self.cellIdentifier(model: model, dimension: dimension))
    }

    // MARK: Diff

    private var diff: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changes since the previous snapshot").font(.headline)
            if service.previous == nil {
                Text("No earlier snapshot to compare with.").foregroundStyle(.secondary)
            } else if service.changes.isEmpty {
                Text("No score moved by 0.01 or more.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(service.changes.enumerated()), id: \.offset) { _, change in
                    Text(Self.describe(change))
                        .font(.callout.monospacedDigit())
                        .accessibilityIdentifier("index-diff-row")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("index-diff")
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.headline)
            ForEach(service.config.sources) { source in
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: Binding(get: { source.enabled }, set: { service.setSourceEnabled(source.id, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                            Text("\(source.url) · \(source.unit)\(source.machineReadable ? " · data file" : "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if let result = service.current?.sources.first(where: { $0.sourceID == source.id }), result.stale {
                        Text("stale: \(result.error ?? "not refreshed")").font(.caption).foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("index-source-\(source.id)")
            }
            ForEach(IndexSourceRegistry.problems(service.config.sources), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Aliases

    private var aliasesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model names").font(.headline)
            Text("Benchmarks name models their own way. A name scores only once it maps to a model here; an unmapped name is ignored.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(service.config.aliases.pending.enumerated()), id: \.offset) { _, e in
                HStack {
                    Text("\(e.source): \"\(e.benchmarkModel)\" → \(IndexKeys.label(e.model))?")
                    Spacer()
                    Button("Confirm") { service.confirmAlias(source: e.source, benchmarkModel: e.benchmarkModel) }
                    Button("Reject") { service.rejectAlias(source: e.source, benchmarkModel: e.benchmarkModel) }
                }
                .accessibilityIdentifier("index-alias-pending")
            }
            ForEach(Array(service.config.aliases.confirmed.enumerated()), id: \.offset) { _, e in
                HStack {
                    Text("\(e.source): \"\(e.benchmarkModel)\" → \(IndexKeys.label(e.model))")
                    Spacer()
                    Button {
                        service.removeAlias(source: e.source, benchmarkModel: e.benchmarkModel)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this mapping")
                }
            }
            if !unmappedWithoutEntry.isEmpty {
                DisclosureGroup("Unmapped names (\(unmappedWithoutEntry.count))") {
                    ForEach(unmappedWithoutEntry, id: \.self) { name in
                        HStack {
                            Text("\(name.source): \"\(name.benchmarkModel)\"")
                            Spacer()
                            Menu("Map to…") {
                                ForEach(knownModels, id: \.self) { m in
                                    Button(IndexKeys.label(m)) {
                                        service.mapAlias(source: name.source, benchmarkModel: name.benchmarkModel, to: m)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private var unmappedWithoutEntry: [UnmappedName] {
        (service.current?.unmapped ?? []).filter {
            service.config.aliases.entry(source: $0.source, benchmarkModel: $0.benchmarkModel) == nil
        }
    }

    private var knownModels: [ModelRef] {
        var seen: [ModelRef] = []
        for m in service.knownCatalogs.enabledModels + service.scores.map(\.model) where !seen.contains(m) { seen.append(m) }
        return seen
    }

    // MARK: Hand-entered scores

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Hand-entered scores").font(.headline)
                Spacer()
                Button("Add…") {
                    editing = ManualDraft(entry: ManualModelScores(model: ModelRef(harness: "opencode", model: ""), dimensions: [:]),
                                          original: nil)
                }
                .accessibilityIdentifier("index-manual-add")
            }
            Text("For local models no benchmark lists. A hand-entered score has confidence 1. Inheriting copies a base model's scores at a discount (0.85 by default).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(service.config.manual.enumerated()), id: \.offset) { _, m in
                HStack {
                    Text(IndexKeys.label(m.model))
                    if let base = m.inheritFrom {
                        Text("inherits \(IndexKeys.label(base)) × \(String(format: "%.2f", m.discount))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editing = ManualDraft(entry: m, original: m.model) }
                    Button { service.removeManual(m.model) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Refresh agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Refresh agent").font(.headline)
            HStack {
                TextField("Model", text: Binding(get: { service.config.agent.model },
                                                 set: { var a = service.config.agent; a.model = $0; service.setAgent(a) }))
                    .frame(width: 160)
                Picker("Effort", selection: Binding(get: { service.config.agent.effort },
                                                    set: { var a = service.config.agent; a.effort = $0; service.setAgent(a) })) {
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 180)
                TextField("Token cap", value: Binding(get: { service.config.agent.tokenCap },
                                                      set: { var a = service.config.agent; a.tokenCap = max(0, $0); service.setAgent(a) }),
                          format: .number)
                    .frame(width: 120)
            }
            Text("Runs claude -p with web search and fetch only, once per enabled source. Sources left when the token cap is reached keep their previous values and are marked stale.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The token cap counts all tokens the agent processes, including cached input it re-reads each turn.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Log

    @ViewBuilder private var logSection: some View {
        if !service.lastLog.isEmpty {
            DisclosureGroup("Last refresh log") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(service.lastLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Citations

    private func citationsSheet(_ cell: CellSelection) -> some View {
        // `citations` matches the model by exact `==`, while `dimensionScore` resolves a bare ref
        // to its best knob variant. Ask with the ref `dimensionScore` returned (the scored
        // variant) so a knobbed alias cannot show a cell that cites nothing.
        let resolved = CapabilityScoring.dimensionScore(cell.model, cell.dimension, in: service.scores)
        let score = resolved?.score
        let rows = service.citations(model: resolved?.model ?? cell.model, dimension: cell.dimension)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(IndexKeys.label(cell.model)) — \(cell.dimension)").font(.headline)
            Text(Self.cellValue(score)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(score?.origin == .computed ? "No cited rows remain for this score."
                                                : "Entered by hand or inherited; no benchmark row stands behind it.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.sourceName): \"\(c.benchmarkModel)\" \(c.quotedFigure)\(c.stale ? " (stale)" : "")")
                        Text(c.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("index-citation-url")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { selectedCell = nil }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("index-citations-done")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: Pure helpers (tested in CapabilityIndexPaneTests)

    static func cellIdentifier(model: ModelRef, dimension: String) -> String {
        "index-cell-\(IndexKeys.key(model))-\(dimension)"
    }

    static func cellValue(_ s: DimensionScore?) -> String {
        guard let s else { return "unknown" }
        let origin: String
        switch s.origin {
        case .computed: origin = "computed"
        case .manual: origin = "manual"
        case .inherited: origin = "inherited from \(s.inheritedFrom.map(IndexKeys.label) ?? "another model")"
        }
        return String(format: "%.2f, confidence %.2f, ", s.score, s.confidence) + origin
    }

    /// Never fully transparent: a low-confidence score must still be visibly a score, not a gap.
    static func cellOpacity(confidence: Double) -> Double { 0.2 + 0.8 * max(0, min(1, confidence)) }

    static func color(for score: Double) -> Color {
        Color(hue: 0.33 * max(0, min(1, score)), saturation: 0.65, brightness: 0.85)
    }

    static func originMark(_ origin: ScoreOrigin) -> String {
        switch origin {
        case .computed: ""
        case .manual: " M"
        case .inherited: " I"
        }
    }

    static func describe(_ c: ScoreChange) -> String {
        let name = "\(IndexKeys.label(c.model)) — \(c.dimension)"
        switch (c.before, c.after) {
        case let (b?, a?): return name + String(format: " %.2f → %.2f (%+.2f)", b, a, a - b)
        case let (nil, a?): return name + String(format: " new %.2f", a)
        case let (b?, nil): return name + String(format: " %.2f → unknown", b)
        case (nil, nil): return name
        }
    }

    static func utc(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f.string(from: date)
    }

    static func shortName(_ dimension: String) -> String {
        [
            "agentic-coding": "Agentic", "algorithmic-reasoning": "Algo", "test-authoring": "Tests",
            "frontend-ui": "UI", "large-context-refactor": "Refactor", "debugging": "Debug", "docs-prose": "Docs",
            "tool-use-reliability": "Tools", "speed": "Speed", "cost-efficiency": "Cost",
        ][dimension] ?? dimension
    }
}

/// Adds or edits one model's hand-entered scores. A blank or out-of-range field is no score —
/// never zero — for the same reason the index never turns unknown into zero.
struct ManualScoresEditor: View {
    let knownModels: [ModelRef]
    let save: (ManualModelScores) -> Void
    private let knobs: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var harness: String
    @State private var model: String
    @State private var texts: [String: String]
    @State private var inherit: ModelRef?
    @State private var discount: Double

    init(entry: ManualModelScores, knownModels: [ModelRef], save: @escaping (ManualModelScores) -> Void) {
        self.knownModels = knownModels
        self.save = save
        self.knobs = entry.model.knobs
        _harness = State(initialValue: entry.model.harness.rawValue)
        _model = State(initialValue: entry.model.model)
        _texts = State(initialValue: entry.dimensions.mapValues { String(format: "%.2f", $0) })
        _inherit = State(initialValue: entry.inheritFrom)
        _discount = State(initialValue: entry.discount)
    }

    var body: some View {
        Form {
            TextField("Harness", text: $harness)
            TextField("Model", text: $model)
            Picker("Inherit from", selection: $inherit) {
                Text("Nothing").tag(ModelRef?.none)
                ForEach(knownModels, id: \.self) { Text(IndexKeys.label($0)).tag(ModelRef?.some($0)) }
            }
            TextField("Discount", value: $discount, format: .number)
            Section("Scores (0 to 1, blank for none)") {
                ForEach(Dimensions.all, id: \.id) { d in
                    TextField(d.id, text: Binding(get: { texts[d.id] ?? "" }, set: { texts[d.id] = $0 }))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(ManualModelScores(model: ModelRef(harness: HarnessID(trimmed(harness)), model: trimmed(model), knobs: knobs),
                                           dimensions: Self.parse(texts), inheritFrom: inherit, discount: discount))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed(harness).isEmpty || trimmed(model).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    static func parse(_ texts: [String: String]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (d, t) in texts {
            if let v = Double(t.trimmingCharacters(in: .whitespaces)), (0...1).contains(v) { out[d] = v }
        }
        return out
    }
}
