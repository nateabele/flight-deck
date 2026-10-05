import IntakeKit
import SwiftUI

/// Settings → Flight Control → Routing (spec L3-R §2, §3, §7): the project's rules — checked
/// first — then the global list. Each rule shows its sentence, its state, its compiled form in
/// plain words, and the buttons that move it on. `RoutingUITests` drives this pane.
struct FlightControlRoutingPane: View {
    @ObservedObject var routing: RoutingService
    @ObservedObject var preferences: PreferencesStore
    let project: String?
    @State private var newGlobal = ""
    @State private var newProject = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let project {
                    ruleList(title: "This project — checked first", scope: .project(project), draft: $newProject,
                             suffix: "project", error: routing.projectRulesError(project))
                }
                ruleList(title: "All projects", scope: .global, draft: $newGlobal, suffix: "global", error: nil)
                compilerFooter
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Loads the catalogs on open, so rule hints have something to compare against. Codex's
        // costs one app-server spawn per launch and is cached after that.
        .task { _ = await routing.catalogs() }
    }

    private func ruleList(title: String, scope: RuleScope, draft: Binding<String>, suffix: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let error {
                Text("routing.json could not be read, so these rules are not routing: \(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("routing-project-error")
            }
            let rules = routing.rules(scope)
            if rules.isEmpty && error == nil {
                Text("No rules yet.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                RuleRow(routing: routing, rule: rule, scope: scope)
            }
            HStack {
                TextField("Use Codex for unit and integration tests, and for complex algorithms", text: draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(draft, to: scope) }
                    .accessibilityIdentifier("routing-add-field-\(suffix)")
                Button("Add") { add(draft, to: scope) }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || error != nil)
                    .accessibilityIdentifier("routing-add-\(suffix)")
            }
        }
    }

    private func add(_ draft: Binding<String>, to scope: RuleScope) {
        if routing.addRule(draft.wrappedValue, to: scope) != nil { draft.wrappedValue = "" }
    }

    /// Which headless model compiles sentences (spec §3: "default `claude -p` haiku, configurable").
    private var compilerFooter: some View {
        HStack(spacing: 8) {
            Text("Rules compile with").foregroundStyle(.secondary)
            Picker("Agent", selection: Binding(get: { preferences.routingCompilerSettings.harness },
                                               set: { preferences.routingCompilerSettings.harness = $0 })) {
                Text("Claude").tag(Harness.claude)
                Text("Codex").tag(Harness.codex)
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityIdentifier("routing-compiler-agent")
            TextField("Model", text: Binding(get: { preferences.routingCompilerSettings.model },
                                             set: { preferences.routingCompilerSettings.model = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .accessibilityIdentifier("routing-compiler-model")
            Spacer()
        }
        .font(.callout)
    }
}

/// One rule: its editable sentence, state, compiled form, failure or compiler note, hint, and
/// actions. The sentence commits on Return, which sends the rule back to draft (spec §2).
struct RuleRow: View {
    @ObservedObject var routing: RoutingService
    let rule: RoutingRule
    let scope: RuleScope
    @State private var editing: String?

    var body: some View {
        let p = RuleRowPresentation(rule: rule, compiling: routing.compiling.contains(rule.id), note: routing.notes[rule.id])
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Sentence", text: Binding(get: { editing ?? rule.sentence }, set: { editing = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .accessibilityIdentifier("routing-sentence-\(rule.id)")
                Text(p.stateLabel)
                    .font(.caption)
                    .foregroundStyle(color(rule.state))
                    .accessibilityIdentifier("routing-state-\(rule.id)")
            }
            if let text = p.compiledText {
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routing-compiled-\(rule.id)")
            }
            if let failure = p.failureText {
                Text(failure).font(.callout).foregroundStyle(.red).accessibilityIdentifier("routing-failure-\(rule.id)")
            }
            if let note = p.note {
                Text(note).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("routing-note-\(rule.id)")
            }
            if let hint = routing.hint(for: rule, scope: scope) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                    Text(hint.text).accessibilityIdentifier("routing-hint-\(rule.id)")
                    Button("Dismiss") { routing.dismissHint(hint) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("routing-hint-dismiss-\(rule.id)")
                }
                .font(.caption)
            }
            HStack {
                Button("Compile") { Task { await routing.compile(rule.id, in: scope) } }
                    .disabled(!p.canCompile)
                    .accessibilityIdentifier("routing-compile-\(rule.id)")
                Button("Confirm") { routing.confirm(rule.id, in: scope) }
                    .disabled(!p.canConfirm)
                    .accessibilityIdentifier("routing-confirm-\(rule.id)")
                Spacer()
                Button { routing.moveRule(rule.id, by: -1, in: scope) } label: { Image(systemName: "arrow.up") }
                    .help("Check this rule earlier")
                    .accessibilityIdentifier("routing-up-\(rule.id)")
                Button { routing.moveRule(rule.id, by: 1, in: scope) } label: { Image(systemName: "arrow.down") }
                    .help("Check this rule later")
                    .accessibilityIdentifier("routing-down-\(rule.id)")
                Button("Delete", role: .destructive) { routing.deleteRule(rule.id, in: scope) }
                    .accessibilityIdentifier("routing-delete-\(rule.id)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-rule-\(rule.id)")
    }

    private func commit() {
        guard let edited = editing else { return }
        routing.editSentence(rule.id, edited, in: scope)
        editing = nil
    }

    private func color(_ state: RuleState) -> Color {
        switch state {
        case .draft: return .secondary
        case .compiled: return .orange
        case .confirmed: return .green
        case .failed: return .red
        }
    }
}
