import IntakeKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Flight Control → Routing (spec L3-R §2, §3, §7): one grouped form, a section per
/// scope — the project's rules (checked first), then all projects'. Each row is the sentence
/// over its compiled pills and one status. Return in "New rule…" adds and compiles; pills open
/// popovers that adjust the compiled rule; the sentence edits inline. No detail sheet exists.
/// `RoutingUITests` drives this pane.
struct FlightControlRoutingPane: View {
    @ObservedObject var routing: RoutingService
    @ObservedObject var preferences: PreferencesStore
    let project: String?

    @FocusState private var focus: RoutingFocus?
    @State private var selection: String?
    @State private var editing: String?
    @State private var drafts: [RuleScope: String] = [:]
    @State private var dragging: String?
    @State private var drop: DropMark?
    @State private var showsCompiler = false

    init(routing: RoutingService, preferences: PreferencesStore, project: String?) {
        self.init(routing: routing, preferences: preferences, project: project, drafts: [:], editing: nil)
    }

    /// `drafts` and `editing` start the pane mid-typing, for `RoutingRenderTests`: both trap
    /// layouts this pane has hit (text pushed to the trailing edge) only show with text in a field.
    init(routing: RoutingService, preferences: PreferencesStore, project: String?,
         drafts: [RuleScope: String], editing: String?) {
        self.routing = routing; self.preferences = preferences; self.project = project
        _drafts = State(initialValue: drafts)
        _editing = State(initialValue: editing)
    }

    /// Where a dragged rule would land: just above `before`, or last in `scope` when nil.
    struct DropMark: Equatable {
        var scope: RuleScope
        var before: String?
        /// The row the line is drawn on, and on which edge.
        var row: String?
        var bottom: Bool
    }

    private var scopes: [RuleScope] {
        (project.map { [RuleScope.project($0)] } ?? []) + [.global]
    }

    var body: some View {
        Form {
            ForEach(scopes, id: \.self) { scope in
                Section {
                    rows(scope)
                } header: {
                    Text(header(scope))
                } footer: {
                    if scope == .global { footer }
                }
            }
        }
        .formStyle(.grouped)
        // Loads the catalogs on open, so hints, pill names and the target popover have something
        // to read. Codex's costs one app-server spawn per launch and is cached after that.
        .task { _ = await routing.catalogs() }
        .onChange(of: focus) { _, now in
            if case .rule(let id) = now { selection = id }
        }
    }

    private func header(_ scope: RuleScope) -> String {
        switch scope {
        case .project(let path): URL(fileURLWithPath: path).lastPathComponent
        case .global: "All projects"
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(_ scope: RuleScope) -> some View {
        let error: String? = if case .project(let path) = scope { routing.projectRulesError(path) } else { nil }
        if let error {
            Label {
                Text("routing.json could not be read, so these rules are not routing: \(error)")
                    .accessibilityIdentifier("routing-project-error")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .foregroundStyle(.red)
        } else {
            let rules = routing.rules(scope)
            ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                RoutingRuleRow(routing: routing, rule: rule, scope: scope,
                               presentation: presentation(rule),
                               hint: routing.hint(for: rule, scope: scope),
                               isSelected: selection == rule.id,
                               isFirst: i == 0, isLast: i == rules.count - 1,
                               focus: $focus, editing: $editing,
                               select: { select(rule.id) },
                               delete: { delete(rule.id, in: scope) },
                               move: moveSelection)
                    .overlay(alignment: drop?.bottom == true ? .bottom : .top) { dropLine(rule.id) }
                    .onDrag {
                        dragging = rule.id
                        return NSItemProvider(object: rule.id as NSString)
                    }
                    .onDrop(of: [.text], delegate: RuleDropDelegate(pane: self, scope: scope, target: rule.id, rules: rules))
            }
            newRuleField(scope)
                .overlay(alignment: .top) { if drop?.scope == scope, drop?.row == nil { line } }
                .onDrop(of: [.text], delegate: RuleDropDelegate(pane: self, scope: scope, target: nil, rules: rules))
        }
    }

    private func presentation(_ rule: RoutingRule) -> RuleRowPresentation {
        RuleRowPresentation(rule: rule, compiling: routing.compiling.contains(rule.id), note: routing.notes[rule.id],
                            catalogs: routing.lastCatalogs, defaultPools: routing.defaultPools(routing.lastCatalogs))
    }

    private func newRuleField(_ scope: RuleScope) -> some View {
        let suffix = if case .global = scope { "global" } else { "project" }
        let text = Binding(get: { drafts[scope] ?? "" }, set: { drafts[scope] = $0 })
        return HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            // The placeholder is drawn by hand: a plain field's own prompt renders in the
            // primary colour inside a grouped form and reads as a rule someone typed.
            // labelsHidden + leading: inside a grouped form a TextField is laid out as a label
            // and a trailing-aligned field, which put the caret and typed text at the row's far
            // right, away from the placeholder (seen on the UI-test Mac).
            TextField("", text: text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .background(alignment: .leading) {
                    if text.wrappedValue.isEmpty {
                        Text("New rule…").foregroundStyle(.tertiary).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .focused($focus, equals: .newRule(scope))
                .onSubmit {
                    // Add-and-compile on Return; the field keeps focus so the next rule can be
                    // typed straight away.
                    if routing.submitNewRule(text.wrappedValue, to: scope) != nil { text.wrappedValue = "" }
                    focus = .newRule(scope)
                }
                .onExitCommand { text.wrappedValue = "" }
                .help("Say when to use which agent, e.g. “Use Codex for tests and hard algorithms”. Return adds the rule and compiles it.")
                .accessibilityLabel(scope == .global ? "New rule for all projects" : "New rule for this project")
                .accessibilityIdentifier("routing-new-\(suffix)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Project rules are checked first, then these, top to bottom — the first match wins. Click a pill to adjust it.")
                .foregroundStyle(.secondary)
                // A grouped form's footer aligns wrapped lines to the trailing edge otherwise.
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(compilerTitle) { showsCompiler = true }
                .buttonStyle(.link)
                .help("Choose which model turns rule sentences into routing")
                .accessibilityIdentifier("routing-compiler")
                .popover(isPresented: $showsCompiler, arrowEdge: .bottom) {
                    RoutingCompilerPopover(routing: routing, preferences: preferences)
                }
        }
        .font(.caption)
    }

    private var compilerTitle: String {
        let s = preferences.routingCompilerSettings
        let h = s.agent
        let model = routing.lastCatalogs.byAgent[h]?.models.first { $0.id == s.model }?.displayName ?? s.model
        return "Compiled by \(RuleRowPresentation.agentName(h)) \(model)"
    }

    // MARK: - Selection and keyboard

    /// Every rule in the order the arrow keys walk: the project's, then everyone's.
    private var order: [(id: String, scope: RuleScope)] {
        scopes.flatMap { scope in routing.rules(scope).map { ($0.id, scope) } }
    }

    private func select(_ id: String) {
        selection = id
        if editing != id { focus = .rule(id) }
    }

    /// ⌫ deletes, then selects the row that took its place, so repeated ⌫ clears a list the way
    /// it does in a Finder list.
    private func delete(_ id: String, in scope: RuleScope) {
        let ids = order.map(\.id)
        let next = ids.firstIndex(of: id).flatMap { i in ids.indices.contains(i + 1) ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil) }
        if editing == id { editing = nil }
        routing.deleteRule(id, in: scope)
        selection = next
        focus = next.map { .rule($0) }
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        let ids = order.map(\.id)
        guard let current = selection, let i = ids.firstIndex(of: current) else {
            if let first = ids.first { select(first) }
            return
        }
        switch direction {
        case .up where i > 0: select(ids[i - 1])
        case .down where i + 1 < ids.count: select(ids[i + 1])
        default: break
        }
    }

    // MARK: - Drag and drop

    @ViewBuilder
    private func dropLine(_ id: String) -> some View {
        if drop?.row == id { line }
    }

    private var line: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, -6)
            .offset(y: drop?.bottom == true ? 5 : -5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Reorders within one section; a drop from the other section is refused, since moving a rule
    /// between scopes would move it between files.
    struct RuleDropDelegate: DropDelegate {
        let pane: FlightControlRoutingPane
        let scope: RuleScope
        /// The row dropped on, or nil for the section's "New rule…" row (drop last).
        let target: String?
        let rules: [RoutingRule]

        private var ids: [String] { rules.map(\.id) }

        func validateDrop(info: DropInfo) -> Bool {
            guard let dragging = pane.dragging else { return false }
            return ids.contains(dragging)
        }

        /// Dragging down lands below the target, dragging up lands above it — what the
        /// insertion line shows.
        private func mark() -> DropMark? {
            guard let dragging = pane.dragging, let from = ids.firstIndex(of: dragging) else { return nil }
            guard let target, let to = ids.firstIndex(of: target) else {
                return DropMark(scope: scope, before: nil, row: nil, bottom: false)
            }
            if to > from {
                return DropMark(scope: scope, before: ids.indices.contains(to + 1) ? ids[to + 1] : nil, row: target, bottom: true)
            }
            return DropMark(scope: scope, before: target, row: target, bottom: false)
        }

        func dropEntered(info: DropInfo) {
            guard validateDrop(info: info), pane.dragging != target else { return }
            withAnimation(.easeOut(duration: 0.12)) { pane.drop = mark() }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
        }

        func dropExited(info: DropInfo) {
            if pane.drop?.row == target, pane.drop?.scope == scope { pane.drop = nil }
        }

        func performDrop(info: DropInfo) -> Bool {
            defer { pane.drop = nil; pane.dragging = nil }
            guard let dragging = pane.dragging, let m = mark(), dragging != target else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                pane.routing.moveRule(dragging, before: m.before, in: scope)
            }
            pane.select(dragging)
            return true
        }
    }
}
