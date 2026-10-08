import IntakeKit
import SwiftUI

/// The shared shape of every Routing popover: a two-column grid, labels on the left in the
/// secondary colour and right-aligned, controls on the right all one width with a shared
/// leading edge, and secondary or destructive actions in their own row below a divider. One
/// container, so no popover drifts into the ragged hand-sized layout the first mockup had.
struct RoutingPopoverForm<Rows: View, Footer: View>: View {
    /// Every control in the right column is exactly this wide, so pop-up buttons, segmented
    /// controls and the slider row all start and end on the same x.
    /// 300 fits codex's six efforts as equal segments (Low … Ultra need about 296 pt); any
    /// narrower and the segmented control overflows the column on both sides.
    static var controlWidth: CGFloat { 300 }

    var error: String?
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                rows()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, error == nil ? 18 : 10)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("routing-popover-error")
            }
            if Footer.self != EmptyView.self {
                Divider()
                HStack(spacing: 8) { footer() }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .fixedSize()
    }
}

extension RoutingPopoverForm where Footer == EmptyView {
    init(error: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
        self.error = error; self.rows = rows; self.footer = { EmptyView() }
    }
}

/// One labelled row of a `RoutingPopoverForm`.
struct RoutingPopoverRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: () -> Control

    init(_ label: String, @ViewBuilder control: @escaping () -> Control) {
        self.label = label; self.control = control
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            // maxWidth first: pop-up buttons and segmented controls hug their content, and a
            // fixed frame alone only positions them, leaving every right edge at a different x.
            control()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: RoutingPopoverForm<EmptyView, EmptyView>.controlWidth, alignment: .leading)
                .accessibilityLabel(label)
        }
    }
}

// MARK: - Condition

/// A condition pill's popover. On an existing condition every change applies at once (the
/// threshold on slider release); the "+" pill opens it empty and adds on "Add Condition".
struct RoutingConditionEditor: View {
    @ObservedObject var routing: RoutingService
    let ruleID: String
    let scope: RuleScope
    let match: RuleMatch
    /// nil for a new condition.
    let index: Int?
    let close: () -> Void

    @State private var isKind = false
    @State private var dimension = Dimensions.all.first?.id ?? ""
    @State private var threshold = 0.5
    @State private var kind: KindID?
    @State private var error: String?
    @State private var loaded = false

    private var kinds: [TaskKind] { routing.kinds(for: scope).filter(\.isLive) }
    private var isAll: Bool { if case .all = match { return true } else { return false } }

    var body: some View {
        RoutingPopoverForm(error: error) {
            RoutingPopoverRow("Type") {
                FillingSegments(selection: Binding(get: { isKind }, set: { isKind = $0; typeChanged() }),
                                items: [(false, "Dimension"), (true, "Task Kind")], identifier: "routing-condition-type")
            }
            if isKind {
                RoutingPopoverRow("Kind") {
                    FillingPopUp(selection: Binding(get: { kind }, set: { kind = $0; applyExisting() }),
                                 items: (kind == nil ? [(KindID?.none, "Choose…")] : [])
                                     + kinds.map { (KindID?.some($0.id), $0.name) },
                                 identifier: "routing-condition-kind")
                }
            } else {
                RoutingPopoverRow("Dimension") {
                    FillingPopUp(selection: Binding(get: { dimension }, set: { dimension = $0; applyExisting() }),
                                 items: Dimensions.all.map { ($0.id, $0.id) }, identifier: "routing-condition-dimension")
                        .help(Dimensions.all.first { $0.id == dimension }?.summary ?? "")
                }
                RoutingPopoverRow("Threshold") {
                    HStack(spacing: 8) {
                        Slider(value: $threshold, in: 0...1, step: 0.05) { editing in
                            if !editing { applyExisting() }
                        }
                        .accessibilityValue(RuleText.number(threshold))
                        .accessibilityIdentifier("routing-condition-threshold")
                        // Fixed width and monospaced, so the track never shifts as the value
                        // changes from 0.5 to 0.55.
                        Text(String(format: "%.2f", threshold))
                            .font(.body.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
            if match.terms.count > (index == nil ? 0 : 1) {
                RoutingPopoverRow("Match") {
                    FillingSegments(selection: Binding(get: { isAll }, set: { all in
                        error = routing.adjust(ruleID, in: scope, .setMode(all: all))
                    }), items: [(false, "Any"), (true, "All")], identifier: "routing-condition-mode")
                }
            }
        } footer: {
            if let index {
                Button("Remove Condition", role: .destructive) {
                    if let why = routing.adjust(ruleID, in: scope, .removeTerm(at: index)) { error = why } else { close() }
                }
                .disabled(match.terms.count <= 1)
                .help(match.terms.count <= 1 ? "A rule needs at least one condition. Delete the rule instead." : "")
                .accessibilityIdentifier("routing-condition-remove")
                Spacer()
            } else {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Add Condition") {
                    if let why = routing.adjust(ruleID, in: scope, .addTerm(term)) { error = why } else { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isKind && kind == nil)
                .accessibilityIdentifier("routing-condition-add")
            }
        }
        .onAppear(perform: load)
    }

    private var term: MatchTerm {
        if isKind, let kind { return .kind(kind) }
        return .dimension(dimension, atLeast: (threshold * 100).rounded() / 100)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let index, match.terms.indices.contains(index) else { return }
        switch match.terms[index] {
        case .dimension(let d, let atLeast): isKind = false; dimension = d; threshold = atLeast
        case .kind(let k): isKind = true; kind = k
        }
    }

    private func typeChanged() {
        if isKind, kind == nil { kind = kinds.first?.id }
        applyExisting()
    }

    /// New conditions wait for "Add Condition"; existing ones apply on every change.
    private func applyExisting() {
        guard let index else { return }
        if isKind, kind == nil { return }
        error = routing.adjust(ruleID, in: scope, .setTerm(at: index, term))
    }
}

// MARK: - Target

/// The target pill's popover: agent, model, the knobs the model declares, and the account pool.
/// It lists only what the adapter and the pools declare, so nothing invalid is pickable.
struct RoutingTargetEditor: View {
    @ObservedObject var routing: RoutingService
    let ruleID: String
    let scope: RuleScope
    let assign: RuleAssign
    @State private var error: String?

    var body: some View {
        let options = routing.targetOptions(for: assign)
        RoutingPopoverForm(error: error) {
            RoutingPopoverRow("Agent") {
                FillingPopUp(selection: Binding(get: { assign.agent }, set: { apply(.setAgent($0)) }),
                             items: options.agents.map { ($0, RuleRowPresentation.agentName($0)) },
                             identifier: "routing-target-agent")
            }
            RoutingPopoverRow("Model") {
                FillingPopUp(selection: Binding(get: { assign.model }, set: { apply(.setModel($0)) }),
                             items: options.models.map { ($0.id, $0.displayName) }, identifier: "routing-target-model")
            }
            ForEach(options.knobs.keys.sorted(), id: \.self) { knob in
                let values = options.knobs[knob] ?? []
                RoutingPopoverRow(knob.prefix(1).uppercased() + knob.dropFirst()) {
                    // Segments while they fit the column; past six they would overflow it.
                    if values.count <= 6 {
                        FillingSegments(selection: Binding(get: { assign.knobs[knob] }, set: { apply(.setKnob(knob, $0)) }),
                                        items: values.map { ($0, Self.short($0)) }, identifier: "routing-target-\(knob)")
                            .help(assign.knobs[knob] == nil ? "Not set: the agent decides" : "")
                    } else {
                        FillingPopUp(selection: Binding(get: { assign.knobs[knob] }, set: { apply(.setKnob(knob, $0)) }),
                                     items: (assign.knobs[knob] == nil ? [(String?.none, "Agent decides")] : [])
                                         + values.map { (String?.some($0), Self.short($0)) },
                                     identifier: "routing-target-\(knob)")
                    }
                }
            }
            RoutingPopoverRow("Accounts") {
                FillingPopUp(selection: Binding(get: { assign.pool }, set: { apply(.setPool($0)) }),
                             items: options.pools.map { ($0.id, $0.label) }, identifier: "routing-target-pool")
            }
        }
    }

    private func apply(_ change: RuleAdjustment) {
        error = routing.adjust(ruleID, in: scope, change)
    }

    /// Segment labels short enough for six efforts to share one control.
    static func short(_ value: String) -> String {
        switch value {
        case "medium": "Med"
        case "xhigh": "XHigh"
        default: value.prefix(1).uppercased() + value.dropFirst()
        }
    }
}

// MARK: - Hint

/// The lightbulb's popover: the capability index's suggestion, with "Switch to …" (applies it
/// as a pill adjustment) and Dismiss. A hint never changes routing on its own.
struct RoutingHintPopover: View {
    @ObservedObject var routing: RoutingService
    let hint: RuleHint
    let scope: RuleScope
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A better-scoring model").font(.headline)
                    Text(hint.text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("routing-hint-text")
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(18)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") {
                    routing.dismissHint(hint)
                    close()
                }
                .accessibilityIdentifier("routing-hint-dismiss")
                if let suggested = hint.suggested {
                    Button("Switch to \(suggested.model)") {
                        if let why = routing.applyHint(hint, in: scope) { error = why } else { close() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("routing-hint-switch")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 360)
    }
}

// MARK: - Compiler

/// Which headless model compiles sentences (spec §3: "default `claude -p` haiku,
/// configurable"). A footer link opens it: it is set once, if ever, and does not earn a row.
struct RoutingCompilerPopover: View {
    @ObservedObject var routing: RoutingService
    @ObservedObject var preferences: PreferencesStore

    private var settings: RuleCompilerSettings { preferences.routingCompilerSettings }

    var body: some View {
        let models = routing.lastCatalogs.byAgent[settings.agent]?.models ?? []
        RoutingPopoverForm {
            RoutingPopoverRow("Agent") {
                FillingPopUp(selection: Binding(get: { settings.agent }, set: { setAgent($0) }),
                             items: [(AgentID.claude, "Claude"), (AgentID.codex, "Codex")], identifier: "routing-compiler-agent")
            }
            RoutingPopoverRow("Model") {
                // Free text only while the catalog is unknown (before the pane's first load, or
                // codex's list failed): a picker with no entries would strand the setting.
                if models.isEmpty {
                    TextField("Model", text: Binding(get: { settings.model },
                                                     set: { preferences.routingCompilerSettings.model = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("routing-compiler-model")
                } else {
                    // A saved model the catalog no longer lists stays visible, not silently replaced.
                    let extra = models.contains { $0.id == settings.model } ? [] : [(settings.model, settings.model)]
                    FillingPopUp(selection: Binding(get: { settings.model },
                                                    set: { preferences.routingCompilerSettings.model = $0 }),
                                 items: extra + models.map { ($0.id, $0.displayName) }, identifier: "routing-compiler-model")
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("A small, fast model is enough: every answer is checked against your agents and accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: RoutingPopoverForm<EmptyView, EmptyView>.controlWidth, alignment: .leading)
            }
        }
    }

    /// Switching agent picks that agent's cheapest sensible compiler, not its flagship: the
    /// compile is a tiny, schema-checked answer.
    private func setAgent(_ h: AgentID) {
        guard h != settings.agent else { return }
        var next = settings
        next.agent = h
        let models = routing.lastCatalogs.byAgent[h]
        switch h {
        case .claude: next.model = "haiku"
        case .codex: next.model = models?.defaultModel ?? models?.models.first?.id ?? ""
        // Not agent agents (spec §3.1): the popup above never offers them.
        case .grok, .gemini: return
        }
        preferences.routingCompilerSettings = next
    }
}
