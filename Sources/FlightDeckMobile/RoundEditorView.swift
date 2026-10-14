import FleetKit
import SwiftUI

/// The Rounds inspector when the Mac takes edits: every agent a round configuration runs, as
/// pickers rather than lines. Choosing a fidelity edits a copy that Start then sends; shaping
/// edits the running config and saves it with Save. Both are `RoundEditing`, held as a draft on
/// the detail model, and the Mac judges every edit again when it arrives.
struct RoundEditorView: View {
    let intake: UUID
    let preset: String?
    let model: IntakeDetailModel
    let flightControl: FlightControlModel
    let editing: RoundEditing
    let title: String

    /// The role being given a model by hand ("Other…"), and the text so far.
    @State private var customSite: RoundSite?
    @State private var customAgent = ""
    @State private var customText = ""

    private var editor: RoundEditor { editing.editor }
    private var commands: IntakeCommandModel { flightControl.commands(for: intake) }
    private var shaping: Bool { preset == nil }

    var body: some View {
        List {
            if let message = commands.message {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message).font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button { commands.clearMessage() } label: {
                            Image(systemName: "xmark").font(.caption).frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                    }
                }
            }
            if let reason = editor.lock?.reason {
                Section { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
            }
            if editing.stale && editing.dirty {
                Section {
                    Text("Your Mac changed these rounds after you began. Revert to see them.")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
            ForEach(editor.stages) { stage in
                Section {
                    ForEach(stage.roles) { role in roleRows(role) }
                    stageControls(stage.id)
                } header: {
                    Text(stage.title)
                } footer: {
                    if stage.id == "synthesis" { Text(RoundEditor.synthesisIntegratorNote).font(.caption) }
                }
            }
            Section {
                Picker(selection: Binding(get: { editor.config.defaultPlay }, set: { value in edit { $0.setDefaultPlay(value) } })) {
                    ForEach(["step", "nextMajor", "toReview"], id: \.self) { Text(RoundInspectorModel.playName($0)).tag($0) }
                } label: { Text("Default play").font(.subheadline) }
                .pickerStyle(.menu)
                .accessibilityIdentifier("rounds-default-play")
            }
            .disabled(!editor.editable)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actionBar }
        .alert("\(customAgentName) model", isPresented: customPresented) {
            TextField("Model id", text: $customText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use") { applyCustom() }
            Button("Cancel", role: .cancel) { customSite = nil }
        }
    }

    // MARK: Roles

    @ViewBuilder private func roleRows(_ role: RoundEditor.RoleRows) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(role.title).font(.subheadline.weight(.semibold))
                if let persona = role.persona { Text(persona).font(.caption).foregroundStyle(.secondary) }
                if role.turns.count > 1 { Text(RoundEditor.alternates).font(.caption).foregroundStyle(.secondary) }
                if role.ran { Text(RoundEditor.alreadyRan).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityAddTraits(.isHeader)
        ForEach(role.turns) { turn in
            entryRows(turn.entry, rotation: turn.count > 1 ? turn.count : nil, ran: role.ran)
            if let fallback = turn.fallback { entryRows(fallback, rotation: nil, ran: role.ran) }
        }
        if role.role.rotates, !role.ran, editor.editable {
            rotationButtons(role)
        }
        if role.role == .reviewer { crossCheckRows(ran: role.ran) }
        if role.role == .crossReviewer, editor.crossCheckSameFamily {
            Text("Same family as the reviewer, so rounds won't cross-check.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One choice: its model menu (the agent's icon at its side), then effort where the model has
    /// levels, then the account where there is a choice of them.
    @ViewBuilder private func entryRows(_ entry: RoundEditor.Entry, rotation count: Int?, ran: Bool) -> some View {
        let locked = ran || !editor.editable
        LabeledContent {
            modelMenu(entry)
        } label: {
            HStack(spacing: 8) {
                if let agent = entry.choice?.agent { AgentIcon(agent: agent, size: 22) } else { Color.clear.frame(width: 22, height: 22) }
                Text(entry.label).font(.subheadline)
                if let count, !locked { rotationMenu(entry.site, count: count) }
            }
        }
        .disabled(locked)
        if !entry.efforts.isEmpty, let choice = entry.choice {
            LabeledContent {
                Picker("Effort", selection: Binding(get: { choice.effort }, set: { value in edit { $0.setEffort(entry.site, value) } })) {
                    ForEach(entry.efforts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityIdentifier("rounds-effort")
            } label: { Text("Effort").font(.subheadline).foregroundStyle(.secondary) }
            .disabled(locked)
        }
        if let account = entry.account {
            LabeledContent {
                Picker("Account", selection: Binding(get: { account.selection }, set: { value in edit { $0.setAccount(entry.site, key: value) } })) {
                    ForEach(account.items) { Text($0.title).tag($0.key) }
                    if !account.pools.isEmpty {
                        Divider()
                        ForEach(account.pools) { Label($0.title, systemImage: "square.stack.3d.up").tag($0.key) }
                    }
                    if let missing = account.missing {
                        Divider()
                        Text(missing.title).tag(missing.key)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityIdentifier("rounds-account-picker")
            } label: { Text("Account").font(.subheadline).foregroundStyle(.secondary) }
            .disabled(locked)
        }
    }

    /// "Claude > Opus 5.5" as a menu: a submenu per agent, then its models, the current one checked.
    /// An agent that cannot be picked stays in the list, disabled, with the reason detection gave.
    private func modelMenu(_ entry: RoundEditor.Entry) -> some View {
        Menu {
            if entry.site.fallback {
                Button { edit { $0.clearFallback(entry.site) } } label: { check("None", entry.choice == nil) }
                Divider()
            }
            ForEach(editor.modelMenu(for: entry.site)) { agent in
                if let reason = agent.reason {
                    Button(reason) {}.disabled(true)
                } else {
                    Menu(agent.name) {
                        if let custom = agent.custom { Button {} label: { check(custom.name, true) } }
                        ForEach(agent.models) { item in
                            Button { edit { $0.select(entry.site, agent: agent.agent, model: item.model) } } label: { check(item.name, item.checked) }
                        }
                        Divider()
                        Button("Other…") {
                            customAgent = agent.agent
                            customText = entry.choice?.agent == agent.agent ? entry.choice?.model ?? "" : ""
                            customSite = entry.site
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(entry.modelLabel).font(.subheadline).lineLimit(2).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .accessibilityIdentifier("rounds-model-menu")
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func rotationMenu(_ site: RoundSite, count: Int) -> some View {
        Menu {
            Button { edit { $0.moveInRotation(site.role, from: site.turn, to: site.turn - 1) } } label: {
                Label("Run earlier", systemImage: "arrow.up")
            }
            .disabled(site.turn == 0)
            Button { edit { $0.moveInRotation(site.role, from: site.turn, to: site.turn + 1) } } label: {
                Label("Run later", systemImage: "arrow.down")
            }
            .disabled(site.turn == count - 1)
            Button(role: .destructive) { edit { $0.removeFromRotation(site.role, at: site.turn) } } label: {
                Label("Take out of the rotation", systemImage: "minus.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.subheadline)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Turn \(site.turn + 1) options")
    }

    @ViewBuilder private func rotationButtons(_ role: RoundEditor.RoleRows) -> some View {
        if role.canAdd {
            Button { edit { $0.addToRotation(role.role) } } label: {
                Label("Add an agent to alternate", systemImage: "plus").font(.subheadline)
            }
        }
        if role.turns.count > 1 {
            Button { edit { $0.collapseRotation(role.role) } } label: { Text("Use one agent").font(.subheadline) }
        }
    }

    // MARK: Stage settings

    @ViewBuilder private func crossCheckRows(ran: Bool) -> some View {
        Picker(selection: Binding(get: { editor.crossCheck }, set: { value in edit { $0.setCrossCheck(value) } })) {
            ForEach(["off", "firstAndLast", "every"], id: \.self) { Text(RoundInspectorModel.crossCheckName($0)).tag($0) }
        } label: { Text("Cross-check").font(.subheadline) }
        .pickerStyle(.menu)
        .disabled(ran || !editor.editable)
        .accessibilityIdentifier("rounds-cross-check")
        if editor.crossCheckUnavailable {
            Text("Cross-checks need a second model family; only one is installed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func stageControls(_ stage: String) -> some View {
        switch stage {
        case "refine":
            Stepper(value: Binding(get: { editor.refineRounds }, set: { value in edit { $0.setRefineRounds(value) } }),
                    in: editor.refineRange) { roundsLabel(editor.refineRounds) }
                .disabled(editor.refineLocked || !editor.editable)
                .accessibilityLabel("Refine rounds")
        case "polish":
            Stepper(value: Binding(get: { editor.polishRounds }, set: { value in edit { $0.setPolishRounds(value) } }),
                    in: editor.polishRange) { roundsLabel(editor.polishRounds) }
                .disabled(editor.polishLocked || !editor.editable)
                .accessibilityLabel("Polish rounds")
            Toggle(isOn: Binding(get: { editor.freshEyes }, set: { value in edit { $0.setFreshEyes(value) } })) {
                Text("Fresh eyes + dedup").font(.subheadline)
            }
            .disabled(editor.freshEyesLocked || !editor.editable)
        default:
            EmptyView()
        }
    }

    private func roundsLabel(_ n: Int) -> some View {
        HStack {
            Text("Rounds").font(.subheadline)
            Spacer()
            Text("\(n)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: Editing and sending

    private func edit(_ change: (inout RoundEditor) -> Void) {
        var next = editor
        change(&next)
        let draft = RoundDraft(base: editing.base, config: next.config)
        model.roundDrafts[editing.key] = RoundEditing.differs(draft) ? draft : nil
    }

    private var customAgentName: String { editor.menu.agents.first { $0.agent == customAgent }?.name ?? "Agent" }
    private var customPresented: Binding<Bool> {
        Binding(get: { customSite != nil }, set: { if !$0 { customSite = nil } })
    }

    private func applyCustom() {
        let id = customText.trimmingCharacters(in: .whitespaces)
        defer { customSite = nil }
        guard let site = customSite, !id.isEmpty else { return }
        edit { $0.select(site, agent: customAgent, model: id) }
    }

    /// While shaping: Revert and Save. While choosing the edit is sent by Start, so the bar only
    /// says so and offers to put the fidelity back.
    @ViewBuilder private var actionBar: some View {
        if editing.dirty {
            VStack(spacing: 6) {
                if !shaping {
                    Text("Start sends these rounds.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(shaping ? "Revert" : "Reset") { model.roundDrafts[editing.key] = nil }
                        .buttonStyle(.bordered)
                    if shaping {
                        Button { save() } label: {
                            Text(commands.inFlight.contains(.rounds) ? "Saving…" : "Save").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(commands.inFlight.contains(.rounds) || !editor.editable)
                    }
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func save() {
        let draft = editing.draft
        let key = editing.key
        commands.send(.rounds, command: { .intakeRounds(id: intake, token: $0, config: draft.config, base: draft.base) },
                      onAck: { model.roundDrafts[key] = nil; model.refresh() },
                      // The plan moved under the edit: what it was made from is gone, so it goes too.
                      onFailure: { error in
                          if case .server(code: "rounds_changed")? = error { model.roundDrafts[key] = nil; model.refresh() }
                      })
    }
}
