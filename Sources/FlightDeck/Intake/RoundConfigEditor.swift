import IntakeKit
import SwiftUI

/// Identifies one editable seat in a `RoundConfig` without a literal Swift `KeyPath` — the
/// seats don't share a type (`drafters` is an array of `Slot`, `synthesizer`/`reviewer` are
/// optional `Slot`s, `integrator`/`encoder` are bare `ModelChoice`, `polisher` is an optional
/// `ModelChoice`), so one `WritableKeyPath<RoundConfig, X>` type can't address all of them.
/// This is the deviation from the brief's literal "keyPath" tuple member — the name is kept,
/// the type isn't.
public enum SlotKeyPath: Hashable {
    case drafter(Int)
    case synthesizer
    case reviewer
    case crossReviewer
    case integrator
    case encoder
    case polisher
    /// The later entries (1...) of a rotating role (`RoundConfig.reviewers`, `integrators`,
    /// `polishers`); entry 0 is always the role's own case above, the single field an older reader
    /// sees. `RotatingRole.keyPath(at:)` makes the right one for an index.
    case reviewerEntry(Int)
    case integratorEntry(Int)
    case polisherEntry(Int)
}

/// The three roles that repeat round after round and can take their agents in turn.
enum RotatingRole: CaseIterable {
    case reviewer, integrator, polisher

    func keyPath(at index: Int) -> SlotKeyPath {
        switch self {
        case .reviewer: index == 0 ? .reviewer : .reviewerEntry(index)
        case .integrator: index == 0 ? .integrator : .integratorEntry(index)
        case .polisher: index == 0 ? .polisher : .polisherEntry(index)
        }
    }
}

extension SlotKeyPath {
    /// The rotating role this seat belongs to, with its place in the rotation.
    var rotation: (role: RotatingRole, index: Int)? {
        switch self {
        case .reviewer: (.reviewer, 0)
        case .integrator: (.integrator, 0)
        case .polisher: (.polisher, 0)
        case .reviewerEntry(let i): (.reviewer, i)
        case .integratorEntry(let i): (.integrator, i)
        case .polisherEntry(let i): (.polisher, i)
        case .drafter, .synthesizer, .crossReviewer, .encoder: nil
        }
    }
}

/// Lets the human tune a chosen preset's expanded `RoundConfig` before shaping starts. Its home
/// is the detail pane's inspector (spec §9): the awaiting-choice body shows only `summary` and
/// an Edit in Inspector button, since a five-column grid pushed the way forward off screen.
struct RoundConfigEditor: View {
    let preset: Preset
    @Binding var config: RoundConfig
    let available: AvailableModels
    /// Each agent's accounts for this intake's project (`IntakeService.planningAccountMenus`): what
    /// the project's assignment bills (the default a role uses unless it picks its own) and the
    /// accounts and pools a role could pick instead (unify brief R9). Empty (no resolver) hides the
    /// Account row.
    var accounts: [AgentID: AccountMenu] = [:]
    /// Set once shaping has started: which agents already ran (shown disabled, "already ran")
    /// and the tape's extend/trim counters, which the caps are shown and saved against. nil
    /// before shaping, where every field is open and a cap is just the cap.
    var shaping: ShapingEdit?
    /// While a round runs: the whole panel shows, disabled (`DetailLayout.RoundsEditing`).
    var readOnly = false
    /// "Check again" beside the sign-in notes: re-runs agent detection
    /// (`IntakeService.recheckAgents`). nil (a render or a test host) shows no button.
    var recheck: AgentRecheck?
    /// The section a round's stack just opened the inspector on, marked until the pane clears
    /// it — a section near the end can't scroll to the top, so the mark is what says which.
    var highlight: RoundsSection?
    /// The tape the timeline marks rounds done and live from (nil before shaping: all planned),
    /// and a start a play just asked for, live before the runner writes it.
    var tape: Tape?
    var starting: PlannedRound?
    /// The picked stage and chip, when the pane shares it with the main view (`IntakeDetailView`
    /// keeps it, so a round clicked there is picked here and back). nil keeps it in the editor.
    var selection: Binding<RoundTimeline.Selection?>?
    /// A chip picked here: the pane shows that round in the main view, if it has run or runs.
    var onPickRound: ((RoundChipModel) -> Void)?

    /// The selection when no pane shares one — a render, the awaiting-choice editor before a
    /// pane wires it. Scoped to this view so a pick never invalidates anything above it.
    @State private var ownSelection: RoundTimeline.Selection?

    /// The model being typed in by hand ("Other…"), and the text so far.
    @State private var custom: CustomModelEntry?
    @State private var customText = ""

    struct CustomModelEntry: Hashable {
        var site: ChoiceSite
        var agent: AgentID
    }

    /// What the "Check again" button needs from the service: whether a detection is running
    /// (spinner, button disabled) and how to start one.
    struct AgentRecheck {
        var isRunning: Bool
        var action: () -> Void
    }

    var body: some View {
        // The whole inspector panel, under a plain title: a disclosure here would be a second
        // way to hide what the panel was opened to show.
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.label(preset: preset, config: config)).font(.headline)
            ForEach(Self.unavailableNotes(available), id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let recheck, Self.offersRecheck(available) {
                recheckRow(recheck)
            }
            ForEach(Self.dataUseNotes(available), id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            stackedSlots
            Divider()
            capsForm.disabled(readOnly)
        }
    }

    /// Directly under the sign-in notes it answers: an agent signed in after launch (`grok
    /// login`) otherwise stayed missing from every menu until Flight Deck was relaunched.
    private func recheckRow(_ recheck: AgentRecheck) -> some View {
        HStack(spacing: 6) {
            Button(Self.recheckTitle, action: recheck.action)
                .controlSize(.small)
                .disabled(recheck.isRunning)
                .help("Look for signed-in agents again")
                .accessibilityIdentifier("rounds-recheck-agents")
            if recheck.isRunning {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static let recheckTitle = "Check again"

    /// Only beside a note the editor shows: a sign-in hint, or a check that failed or timed out
    /// (which reads as the same hint). A CLI that is merely not installed has no note, so a
    /// button there would sit beside nothing.
    static func offersRecheck(_ available: AvailableModels) -> Bool {
        !unavailableNotes(available).isEmpty
    }

    /// The caption beside an agent whose stages have all run.
    static let alreadyRan = "already ran"

    /// Spec §3.9. No settings URL: those pages move.
    static let dataUseNote = "Check Google's data settings before using Gemini agents on private repos."

    /// One line per harness that is installed but not offered, in `AgentID.planningOrder` order,
    /// each the profile's own reason (e.g. "Gemini: run `agy` in a terminal to sign in").
    /// "not installed" is left out: a CLI the human never installed is not news.
    static func unavailableNotes(_ available: AvailableModels) -> [String] {
        AgentID.planningOrder.compactMap { available.unavailable[$0] }.filter { !$0.hasSuffix("not installed") }
    }

    /// The rounds as a timeline (one row per stage, in run order, a chip per round) with the
    /// picked stage's agents beneath its chips. A seat's controls sit on two lines: a five-column
    /// grid needed ~530 pt, and an inspector column is narrower than that.
    ///
    /// Each chip is a `RoundChip` from `RoundTimeline` — the same chip the main view's round
    /// cards and live header draw — so a round there visibly matches its chip here, and picking
    /// either picks the other. The pickers stay role-based: an edit applies to the whole stage,
    /// which the caption under them says.
    private var stackedSlots: some View {
        let rows = RoundTimeline.rows(config: config, tape: tape, starting: starting)
        let picked = currentSelection
        let revealed = picked?.section ?? RoundTimeline.defaultSection(rows)
        let groups = Self.sections(of: config)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(rows, id: \.section) { row in
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading(row.section, open: row.section == revealed)
                    if row.chips.isEmpty {
                        Text(Self.noRounds).font(.caption).foregroundStyle(.tertiary)
                    } else {
                        ChipFlow {
                            ForEach(row.chips) { chip in
                                RoundChip(model: chip, selected: picked?.round == chip.key) { pick(chip) }
                            }
                        }
                    }
                    if row.section == revealed {
                        stagePanel(row.section, rows: groups.first { $0.section == row.section }?.rows ?? [])
                    }
                }
                .id(row.section.anchor)
            }
        }
        .animation(.smooth(duration: 0.2), value: revealed)
    }

    /// Under a stage with no rounds planned (a refine cap of 0).
    static let noRounds = "No rounds"

    private var currentSelection: RoundTimeline.Selection? { selection?.wrappedValue ?? ownSelection }

    private func select(_ next: RoundTimeline.Selection?) {
        if let selection { selection.wrappedValue = next } else { ownSelection = next }
    }

    private func pick(_ chip: RoundChipModel) {
        let next = RoundTimeline.select(currentSelection, chip: chip.key)
        select(next)
        if next.round != nil { onPickRound?(chip) }
    }

    /// The picked stage's controls: what the edit reaches, every seat the stage runs, then the
    /// stage's own settings — the caps live with the rounds they count.
    @ViewBuilder
    private func stagePanel(_ section: RoundsSection,
                            rows: [(role: String, persona: DrafterPersona?, keyPath: SlotKeyPath)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RoundTimeline.caption(section)).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("rounds-stage-caption")
            if section == .synthesis {
                Text(Self.synthesisIntegratorNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(rows.enumerated()), id: \.element.keyPath) { index, row in
                if index > 0 { Divider() }
                slotBlock(row)
            }
            switch section {
            case .refine: refineCap
            case .polish: polishControls
            default: EmptyView()
            }
        }
        .padding(.top, 2)
        // Only the settings lock while a round runs: the timeline above stays live, since
        // picking a chip changes nothing that runs — it shows the round.
        .disabled(readOnly)
        .transition(.opacity)
    }

    /// Where the synthesis section says who merges it: the integrator's one row sits under
    /// Refine, but it runs in the synthesis round too, and its glyph is in its chip's stack.
    static let synthesisIntegratorNote = "The integrator, set under Refine, merges the synthesis."

    /// The stage's heading: a disclosure that reveals its agents. The chevron is the System
    /// Settings / Xcode inspector cue for "this opens"; only one stage is open at a time, so the
    /// column stays short enough for the pickers to sit beside their chips.
    private func sectionHeading(_ section: RoundsSection, open: Bool) -> some View {
        Button { select(RoundTimeline.Selection(section: section, round: nil)) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(highlight == section ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityIdentifier("rounds-section-\(section.rawValue)")
    }

    @ViewBuilder
    private func slotBlock(_ row: (role: String, persona: DrafterPersona?, keyPath: SlotKeyPath)) -> some View {
        if let choice = Self.choice(for: row.keyPath, in: config) {
            let ran = shaping?.isLocked(row.keyPath) == true
            let entries = Self.entries(of: row.keyPath, in: config)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // `.capitalized` title-cases every word, which turns "cross-check
                    // agent" into "Cross-Check Agent" — `sentenceCase` only raises the
                    // first letter, so the role reads as the phrase `UIText` intends.
                    Text(UIText.sentenceCase(UIText.roleName(row.role))).font(.callout.weight(.semibold))
                    if let persona = row.persona, persona != .general {
                        Text(persona.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    if entries.count > 1 {
                        Text(Self.alternates).font(.caption).foregroundStyle(.secondary)
                    }
                    if ran {
                        Text(Self.alreadyRan).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    agentRow(entry, rotation: row.keyPath.rotation.map { (role: $0.role, index: index, count: entries.count) },
                             fallbackShown: Self.supportsFallback(entry))
                }
                if let role = row.keyPath.rotation?.role, Self.canAddToRotation(config, role, available: available) {
                    HStack(spacing: 10) {
                        Button { config = Self.addingToRotation(config, role, available: available) } label: {
                            Label("Add an agent to alternate", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Take turns with another agent, round after round")
                        if entries.count > 1 {
                            Button("Use one agent") { config = Self.collapsingRotation(config, role) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.caption)
                }
                // Only reached once the crossReviewer row itself is showing (policy
                // not off), so the caption never appears while the picker reads "Off".
                if row.keyPath == .crossReviewer, Self.crossCheckSameFamily(config) {
                    Text("Same family as the reviewer, so rounds won't cross-check.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // Its stages are on the tape: a change would reach no round that runs.
            .disabled(ran)
        }
        // Directly under the reviewer row (spec: coverage §8) rather than folded into
        // its own block above — the policy can be live with no crossReviewer row yet
        // showing (nothing seeded), so it can't be gated on `Self.choice(for:)` the way
        // every other row is.
        if row.keyPath == .reviewer, config.reviewer != nil {
            crossCheckPicker.disabled(shaping?.isLocked(.reviewer) == true)
        }
    }

    /// One agent's controls: its glyph, then the one "Claude > Opus 5.5" menu, effort where the
    /// model takes it, the account, and the fallback. A rotating role's entries also get a position
    /// and move/remove buttons once there are two.
    private func agentRow(_ keyPath: SlotKeyPath, rotation: (role: RotatingRole, index: Int, count: Int)?,
                          fallbackShown: Bool) -> some View {
        let site = ChoiceSite(keyPath: keyPath)
        let choice = Self.choice(at: site, in: config)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let rotation, rotation.count > 1 {
                    Text("\(rotation.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                // The glyph the main view's stacks draw for this agent, beside its picker.
                AgentBadge(agent: choice?.agent ?? .codex, size: 18)
                modelMenu(site, noneTitle: nil)
                effortPicker(site)
                if let rotation, rotation.count > 1 {
                    rotationButtons(rotation)
                }
            }
            customModelField(site)
            accountRow(site)
            if fallbackShown {
                let fallbackSite = ChoiceSite(keyPath: keyPath, isFallback: true)
                HStack(spacing: 8) {
                    Text("Fallback").foregroundStyle(.secondary)
                    modelMenu(fallbackSite, noneTitle: "None")
                    effortPicker(fallbackSite)
                }
                .font(.callout)
                customModelField(fallbackSite)
                accountRow(fallbackSite)
            }
        }
    }

    private func rotationButtons(_ rotation: (role: RotatingRole, index: Int, count: Int)) -> some View {
        HStack(spacing: 2) {
            Button { config = Self.movingInRotation(config, rotation.role, from: rotation.index, to: rotation.index - 1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(rotation.index == 0)
            .help("Run earlier")
            Button { config = Self.movingInRotation(config, rotation.role, from: rotation.index, to: rotation.index + 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(rotation.index == rotation.count - 1)
            .help("Run later")
            Button { config = Self.removingFromRotation(config, rotation.role, at: rotation.index) } label: {
                Image(systemName: "minus.circle")
            }
            .help("Take this agent out of the rotation")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// "Cross-check" policy picker: Off / First and last / Every round. Turning it on from
    /// `.off` seeds `crossReviewer` from the OTHER harness the moment it's missing — an
    /// unseeded row would show a picker with a persisted model field it can't yet resolve, and
    /// a same-family default would file the round straight into `crossCheckSameFamily` on the
    /// very first turn.
    private var crossCheckPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Cross-check").foregroundStyle(.secondary)
                Picker("Cross-check", selection: crossCheckBinding) {
                    Text("Off").tag(CrossCheckPolicy.off)
                    Text("First and last").tag(CrossCheckPolicy.firstAndLast)
                    Text("Every round").tag(CrossCheckPolicy.every)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .font(.callout)
            if let note = Self.crossCheckUnavailableNote(config, available: available) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The agent and model as one menu: a submenu per agent ("Claude" ▸ "Opus 5.5", …), closed it
    /// reads "Claude > Opus 5.5". An agent that is not usable stays in the list, disabled, with the
    /// reason detection gave. With `noneTitle`, the menu also offers no choice at all (a fallback).
    private func modelMenu(_ site: ChoiceSite, noneTitle: String?) -> some View {
        let choice = Self.choice(at: site, in: config)
        return Menu {
            if let noneTitle {
                Button { setFallback(site, nil) } label: { Self.checked(noneTitle, choice == nil) }
                Divider()
            }
            ForEach(Self.menuAgents(in: available, chosen: choice?.agent), id: \.self) { agent in
                if let reason = Self.unavailableReason(agent, available: available) {
                    Text(reason).disabled(true)
                } else {
                    Menu(agent.displayName) {
                        let current = choice?.agent == agent ? choice : nil
                        let options = available.menuOptions(for: agent, account: current?.account)
                        if let current, !current.model.isEmpty, !options.contains(where: { $0.id == current.model }) {
                            Button { } label: { Self.checked(available.modelLabel(agent: agent, model: current.model, account: current.account)
                                .replacingOccurrences(of: "\(agent.displayName) > ", with: ""), true) }
                        }
                        ForEach(options, id: \.id) { option in
                            Button { select(site, agent: agent, model: option.id) } label: { Self.checked(option.name, current?.model == option.id) }
                        }
                        Divider()
                        Button(Self.otherModel) {
                            customText = current?.model ?? ""
                            custom = CustomModelEntry(site: site, agent: agent)
                        }
                    }
                }
            }
        } label: {
            Text(choice.map { available.modelLabel(agent: $0.agent, model: $0.model, account: $0.account) } ?? (noneTitle ?? ""))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("rounds-model-menu")
    }

    /// The "Other…" row in an agent's submenu: a model id typed in, for a model no list names.
    @ViewBuilder
    private func customModelField(_ site: ChoiceSite) -> some View {
        if let entry = custom, entry.site == site {
            HStack(spacing: 6) {
                Text("\(entry.agent.displayName) model").font(.caption).foregroundStyle(.secondary)
                TextField("Model id", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyCustomModel(entry) }
                Button("Use") { applyCustomModel(entry) }
                    .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { custom = nil }
            }
            .controlSize(.small)
        }
    }

    private func applyCustomModel(_ entry: CustomModelEntry) {
        let model = customText.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        select(entry.site, agent: entry.agent, model: model)
        custom = nil
    }

    private func select(_ site: ChoiceSite, agent: AgentID, model: String) {
        config = Self.selecting(config, at: site, agent: agent, model: model, available: available)
    }

    private func setFallback(_ site: ChoiceSite, _ choice: ModelChoice?) {
        config = Self.updatingFallback(config, at: site.keyPath, to: choice)
    }

    /// A menu row with a check mark beside the current one.
    @ViewBuilder
    private static func checked(_ title: String, _ isCurrent: Bool) -> some View {
        if isCurrent { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Effort, only for a model that has levels (`AvailableModels.effortValues`): gemini's ids carry
    /// theirs, opencode has no setting, and claude's Haiku 4.5 takes none.
    @ViewBuilder
    private func effortPicker(_ site: ChoiceSite) -> some View {
        if let choice = Self.choice(at: site, in: config) {
            let levels = Self.effortLevels(for: choice, available: available)
            if !levels.isEmpty {
                Picker("Effort", selection: effortBinding(site)) {
                    ForEach(levels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("rounds-effort")
            }
        }
    }

    /// "Account": a picker when the agent has more than one account or pool to choose from (the
    /// project's assignment first), else the account it resolves to as text. A role that holds its
    /// own account keeps the picker, so it can be put back.
    @ViewBuilder
    private func accountRow(_ site: ChoiceSite) -> some View {
        if let choice = Self.choice(at: site, in: config), let menu = accounts[choice.agent] {
            switch Self.accountRow(menu, choice: choice) {
            case .picker:
                HStack(spacing: 8) {
                    Text(Self.accountLabel).foregroundStyle(.secondary)
                    Picker(Self.accountLabel, selection: accountBinding(site)) {
                        Text(menu.defaultTitle).tag(AccountChoice?.none)
                        ForEach(menu.options.filter { !$0.isPool }, id: \.choice) { Text($0.title).tag(AccountChoice?.some($0.choice)) }
                        let pools = menu.options.filter(\.isPool)
                        if !pools.isEmpty {
                            Divider()
                            ForEach(pools, id: \.choice) { Label($0.title, systemImage: "square.stack.3d.up").tag(AccountChoice?.some($0.choice)) }
                        }
                        if let own = choice.account, menu.title(for: own) == nil {
                            Divider()
                            Text(own.key.hasPrefix("pool:") ? "Missing pool" : "Missing account").tag(AccountChoice?.some(own))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("rounds-account-picker")
                }
                .font(.callout)
            case .line(let text):
                HStack(spacing: 4) {
                    if menu.problem { Image(systemName: "exclamationmark.triangle.fill").imageScale(.small) }
                    Text(text).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(menu.problem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .help(menu.problem ? "Choose another in Settings → Projects." : "Set per project in Settings → Projects.")
                .accessibilityIdentifier("rounds-account")
            }
        }
    }

    /// Refine's round count, under its agents: changing it adds or takes chips off the strip
    /// above as it changes.
    private var refineCap: some View {
        HStack(spacing: 8) {
            Text("Rounds").foregroundStyle(.secondary)
            Stepper("\(refinementCapBinding.wrappedValue)", value: refinementCapBinding,
                    in: (shaping?.refinementFloor ?? 0)...max(12, refinementCapBinding.wrappedValue))
                .disabled(shaping?.refineDone == true)
                .accessibilityLabel("Refine rounds")
        }
        .font(.callout)
    }

    /// Polish's round count and fresh eyes + dedup — all three run on the polisher, so they sit
    /// with it. The row only exists with a polisher seated (`RoundTimeline.sections`).
    private var polishControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Rounds").foregroundStyle(.secondary)
                Stepper("\(polishCapBinding.wrappedValue)", value: polishCapBinding,
                        in: (shaping?.polishFloor ?? 0)...max(12, polishCapBinding.wrappedValue))
                    .disabled(shaping?.polishDone == true)
                    .accessibilityLabel("Polish rounds")
            }
            GridRow {
                Text("Fresh eyes + dedup").foregroundStyle(.secondary)
                Toggle("", isOn: freshEyesBinding).labelsHidden()
                    .disabled(shaping?.freshEyesDone == true)
            }
        }
        .font(.callout)
    }

    /// Default play, the one setting that belongs to no stage.
    private var capsForm: some View {
        HStack(spacing: 10) {
            Text("Default play").foregroundStyle(.secondary)
            Picker("", selection: defaultPlayBinding) {
                Text("Step").tag(PlayMode.step)
                Text("Next major").tag(PlayMode.nextMajor)
                Text("To review").tag(PlayMode.toReview)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    // MARK: - Bindings (route every edit through `setting`, which flags `customized`)

    private func effortBinding(_ site: ChoiceSite) -> Binding<String> {
        Binding(
            get: { Self.choice(at: site, in: config)?.effort ?? "high" },
            set: { newValue in config = Self.updatingChoice(config, at: site) { $0.effort = newValue } }
        )
    }

    private func accountBinding(_ site: ChoiceSite) -> Binding<AccountChoice?> {
        Binding(
            get: { Self.choice(at: site, in: config)?.account },
            set: { newValue in config = Self.updatingChoice(config, at: site) { $0.account = newValue } }
        )
    }

    private var crossCheckBinding: Binding<CrossCheckPolicy> {
        Binding(
            get: { config.crossCheck ?? .off },
            set: { newValue in config = Self.settingCrossCheck(config, to: newValue, available: available) }
        )
    }

    /// While shaping, the rounds the stage will run — cap plus the tape's extend/trim counter —
    /// so the number agrees with the board's bracket; the cap saved is the one that gives it
    /// (`ShapingEdit.settingRefinementTotal`), and a + already pressed is never counted twice.
    private var refinementCapBinding: Binding<Int> {
        Binding(get: { shaping?.refinementTotal(config) ?? config.refinementCap },
                set: { newValue in
                    config = shaping?.settingRefinementTotal(config, to: newValue)
                        ?? Self.setting(config) { $0.refinementCap = newValue }
                })
    }

    private var polishCapBinding: Binding<Int> {
        Binding(get: { shaping?.polishTotal(config) ?? config.polishCap },
                set: { newValue in
                    config = shaping?.settingPolishTotal(config, to: newValue) ?? Self.setting(config) { $0.polishCap = newValue }
                })
    }

    private var freshEyesBinding: Binding<Bool> {
        // Reads off with no polisher, since that's what will run whatever the stored flag says.
        Binding(get: { config.freshEyesAndDedup && Self.polishControlsEnabled(config) }, set: { newValue in config = Self.setting(config) { $0.freshEyesAndDedup = newValue } })
    }

    private var defaultPlayBinding: Binding<PlayMode> {
        Binding(get: { config.defaultPlay }, set: { newValue in config = Self.setting(config) { $0.defaultPlay = newValue } })
    }

    // MARK: - Pure helpers (also covered directly by RoundConfigEditorTests)

    /// The polish cap and fresh-eyes toggle only mean something with a polisher seated.
    static func polishControlsEnabled(_ config: RoundConfig) -> Bool { config.polisher != nil }

    /// Why those controls are greyed out, or an empty string (no tooltip) when they aren't.
    static func polishControlsHelp(_ config: RoundConfig) -> String {
        polishControlsEnabled(config) ? ""
            : "This fidelity has no polisher, and polish, fresh eyes and dedup all run on the polisher's agent. Choose Feature plan or Full plan to use them."
    }

    /// "<Preset>, customized" once any field has been edited — the panel's title. Wording lives in `UIText.presetName` — a single source
    /// of truth also shared by `IntakeDetailView`.
    static func label(preset: Preset, config: RoundConfig) -> String {
        let base = UIText.presetName(preset)
        return config.customized ? "\(base), customized" : base
    }

    /// The awaiting-choice body's one line (spec §9): "Full plan · 4 drafters · refine ×5 ·
    /// polish ×6 · cross-check R1, R5 · customized". Counts only rounds the planner will
    /// actually run — refine needs a reviewer, polish a polisher (`TapePlanner.sequence`) — so
    /// the line never promises a cycle the inspector has no seat for.
    static func summary(preset: Preset, config: RoundConfig) -> String {
        let drafters = config.drafters.count
        var parts = [UIText.presetName(preset), "\(drafters) drafter\(drafters == 1 ? "" : "s")"]
        if config.reviewer != nil, config.refinementCap > 0 { parts.append("refine ×\(config.refinementCap)") }
        if config.polisher != nil, config.polishCap > 0 { parts.append("polish ×\(config.polishCap)") }
        let crossRounds = crossCheckRounds(config)
        if !crossRounds.isEmpty {
            parts.append("cross-check " + crossRounds.map { "R\($0)" }.joined(separator: ", "))
        }
        if config.customized { parts.append("customized") }
        return parts.joined(separator: " · ")
    }

    /// The refine rounds that would cross-check at the current cap — `RoundParticipants`' rule,
    /// the one the planner runs, over `refinementCap` alone: the summary has no tape (and so no
    /// `extraRefinement`) to fold in. Empty whenever `config.crossChecks` is false.
    static func crossCheckRounds(_ config: RoundConfig) -> [Int] {
        RoundParticipants.crossCheckRounds(of: config.refinementCap, config: config)
    }

    /// Whether the crossReviewer picked the same family as the reviewer — the caption under its
    /// row explains why a live policy still won't cross-check anything.
    static func crossCheckSameFamily(_ config: RoundConfig) -> Bool {
        guard config.reviewer != nil, let crossReviewer = config.crossReviewer else { return false }
        return config.reviewerRotation.allSatisfy { $0.choice.agent == crossReviewer.choice.agent }
    }

    /// The caption under the Cross-check picker when the policy is on but no cross-check agent
    /// could be seated: only one harness is installed, so `settingCrossCheck` had no other
    /// family to seed. Without it the picker read "First and last" and nothing else changed —
    /// no agent row, no marked rounds, and no word why (spec §3: the inspector explains).
    static func crossCheckUnavailableNote(_ config: RoundConfig, available: AvailableModels) -> String? {
        guard let policy = config.crossCheck, policy != .off, config.crossReviewer == nil, let reviewer = config.reviewer,
              otherModel(for: reviewer.choice, available: available) == nil else { return nil }
        return "Cross-checks need a second model family; only one is installed."
    }

    /// Sets the policy and, the moment it goes live with nothing seeded yet, fills
    /// `crossReviewer` from the OTHER harness's `available` choice — reusing `otherModel`
    /// keeps "the opposite family" defined in exactly one place.
    static func settingCrossCheck(_ config: RoundConfig, to policy: CrossCheckPolicy, available: AvailableModels) -> RoundConfig {
        setting(config) { cfg in
            cfg.crossCheck = policy
            if policy != .off, cfg.crossReviewer == nil, let reviewer = cfg.reviewer,
               let seed = Self.otherModel(for: reviewer.choice, available: available) {
                cfg.crossReviewer = Slot(seed)
            }
        }
    }

    /// `ultra` enables delegation and isn't Pro, so it's excluded even though `effort` is a
    /// bare `String` that would accept it. Claude's profile's values; see `effortChoices(for:)`.
    static let effortChoices = ClaudeProfile.catalog.effortValues

    /// The effort values `harness`'s profile accepts. Empty means the CLI has no effort knob,
    /// and the row hides the picker rather than offer a setting that does nothing.
    static func effortChoices(for agent: AgentID) -> [String] {
        AgentProfiles.profile(for: agent).modelCatalog.effortValues
    }

    /// The models the model field's menu offers for `harness`: its profile's static aliases,
    /// then codex's runtime list when routing has one cached, else the profile's default —
    /// never empty for a harness with a catalog, never a duplicate. `detected` is the list the
    /// CLI itself printed at detection (`grok models`); when there is one it REPLACES the static
    /// aliases, which are only a fallback and go stale as the vendor ships models (grok's moved
    /// from 4.6 to 4.7 on the day it was first probed).
    static func modelSuggestions(for agent: AgentID, codexListed: [String] = [], detected: [String] = []) -> [String] {
        let catalog = AgentProfiles.profile(for: agent).modelCatalog
        var out: [String] = []
        let known = detected.isEmpty ? catalog.aliases : detected
        for model in known + (agent == .codex ? codexListed : []) where !out.contains(model) {
            out.append(model)
        }
        if out.isEmpty, !catalog.defaultPlanningModel.isEmpty { out = [catalog.defaultPlanningModel] }
        return out
    }

    /// What the Account row shows for a role: a picker (the agent has more than one account or pool,
    /// or the role already holds its own), else the resolved account as text.
    enum AccountRowKind: Equatable {
        case picker
        case line(String)
    }

    static let accountLabel = "Account"
    static let otherModel = "Other…"

    static func accountRow(_ menu: AccountMenu, choice: ModelChoice) -> AccountRowKind {
        menu.offersChoice || choice.account != nil ? .picker : .line("\(accountLabel): \(menu.projectDefault)")
    }

    /// The effort levels shown for `choice`: its model's, with a stored level the model no longer
    /// lists kept in so the picker never reads blank. Empty hides the control.
    static func effortLevels(for choice: ModelChoice, available: AvailableModels) -> [String] {
        let levels = available.effortValues(agent: choice.agent, model: choice.model, account: choice.account)
        guard !levels.isEmpty else { return [] }
        return levels.contains(choice.effort) || choice.effort.isEmpty ? levels : levels + [choice.effort]
    }

    /// The agents detection offers — installed and signed in.
    static func agents(in available: AvailableModels) -> [AgentID] {
        available.agents
    }

    /// Every agent a model menu lists, in `AgentID.planningOrder` order: the usable ones, those
    /// installed but not usable (shown disabled with their reason), and the row's own agent when
    /// detection no longer offers it, so a re-check never blanks a role.
    static func menuAgents(in available: AvailableModels, chosen: AgentID?) -> [AgentID] {
        AgentID.planningOrder.filter {
            available.choice(for: $0) != nil || available.unavailable[$0] != nil || $0 == chosen
        }
    }

    /// Why `agent` cannot be picked: detection's own reason (sign-in hint, "not installed"), or
    /// "<Agent> (unavailable)" for a chosen agent detection no longer lists. nil: usable.
    static func unavailableReason(_ agent: AgentID, available: AvailableModels) -> String? {
        guard available.choice(for: agent) == nil else { return nil }
        return available.unavailable[agent] ?? "\(agent.displayName) (unavailable)"
    }

    /// The editor's one block of notes: why an installed-but-unusable harness is missing from
    /// the pickers (spec §3.2: never silently dropped), then the data-use caution for each
    /// consumer-plan harness that IS offered (spec §3.9). One list, so a harness never gets
    /// its reason shown twice by two blocks.
    static func availabilityNotes(_ available: AvailableModels) -> [String] {
        unavailableNotes(available) + dataUseNotes(available)
    }

    /// The data-use cautions alone, for each consumer-plan agent that IS offered — drawn after
    /// "Check again" so the button sits with the notes it re-checks.
    static func dataUseNotes(_ available: AvailableModels) -> [String] {
        var notes: [String] = []
        if available.choice(for: .grok) != nil {
            notes.append("Grok may use prompts to improve its models. Check xAI's data settings before using it on private repos.")
        }
        if available.choice(for: .gemini) != nil { notes.append(dataUseNote) }
        return notes
    }

    /// One row per filled seat, in the fixed order the round actually runs: every drafter,
    /// then synthesizer, reviewer, crossReviewer, integrator, encoder, polisher. Skips
    /// synthesizer/reviewer/polisher when the preset has none, rather than emitting a row with
    /// nothing to bind to — and skips crossReviewer whenever the policy reads `.off`/nil, even
    /// if a `Slot` is sitting there seeded and ready, so the row only shows once it's live.
    static func slots(of config: RoundConfig) -> [(role: String, persona: DrafterPersona?, keyPath: SlotKeyPath)] {
        var rows: [(role: String, persona: DrafterPersona?, keyPath: SlotKeyPath)] = []
        for (i, slot) in config.drafters.enumerated() {
            rows.append(("drafter", slot.persona, .drafter(i)))
        }
        if let synthesizer = config.synthesizer {
            rows.append(("synthesizer", synthesizer.persona, .synthesizer))
        }
        if let reviewer = config.reviewer {
            rows.append(("reviewer", reviewer.persona, .reviewer))
            if let policy = config.crossCheck, policy != .off, let crossReviewer = config.crossReviewer {
                rows.append(("crossReviewer", crossReviewer.persona, .crossReviewer))
            }
        }
        rows.append(("integrator", nil, .integrator))
        rows.append(("encoder", nil, .encoder))
        if config.polisher != nil {
            rows.append(("polisher", nil, .polisher))
        }
        return rows
    }

    /// `slots(of:)`'s rows under the inspector section each belongs to, in run order — every
    /// row once. The integrator sits under Refine, the stage it runs every round of; synthesis
    /// runs it once more, which that section's note and stack say (`synthesisIntegratorNote`).
    static func sections(of config: RoundConfig)
        -> [(section: RoundsSection, rows: [(role: String, persona: DrafterPersona?, keyPath: SlotKeyPath)])] {
        let rows = slots(of: config)
        return RoundsSection.allCases.compactMap { section in
            let mine = rows.filter { Self.section(of: $0.keyPath) == section }
            return mine.isEmpty ? nil : (section, mine)
        }
    }

    static func section(of keyPath: SlotKeyPath) -> RoundsSection {
        switch keyPath {
        case .drafter: .draft
        case .synthesizer: .synthesis
        case .reviewer, .crossReviewer, .integrator, .reviewerEntry, .integratorEntry: .refine
        case .encoder: .encode
        case .polisher, .polisherEntry: .polish
        }
    }

    /// Applies `mutate` to a copy of `config` and marks it customized — the one path every
    /// field edit in the view routes through, so "edited anything" and "labeled customized"
    /// can never drift apart.
    static func setting(_ config: RoundConfig, _ mutate: (inout RoundConfig) -> Void) -> RoundConfig {
        var next = config
        mutate(&next)
        next.customized = true
        return next
    }

    /// "Alternates each round" beside a role that takes more than one agent in turn.
    static let alternates = "alternates each round"

    /// The seats a row shows, in rotation order: a rotating role's entries, else the one seat.
    static func entries(of keyPath: SlotKeyPath, in config: RoundConfig) -> [SlotKeyPath] {
        guard let role = keyPath.rotation?.role else { return [keyPath] }
        return (0..<max(rotationCount(config, role), 1)).map(role.keyPath(at:))
    }

    static func rotationCount(_ config: RoundConfig, _ role: RotatingRole) -> Int {
        switch role {
        case .reviewer: config.reviewerRotation.count
        case .integrator: config.integratorRotation.count
        case .polisher: config.polisherRotation.count
        }
    }

    /// Whether the role offers "Add an agent": it is seated, and a second agent is installed.
    static func canAddToRotation(_ config: RoundConfig, _ role: RotatingRole, available: AvailableModels) -> Bool {
        let seated = switch role {
        case .reviewer: config.reviewer != nil
        case .integrator: true
        case .polisher: config.polisher != nil
        }
        return seated && available.agents.count > 1
    }

    /// Appends an agent to the role's rotation: the next installed agent after the last entry's,
    /// so a first press makes the pair and later ones walk the installed families. A role with one
    /// agent becomes a rotation of that agent and the new one.
    static func addingToRotation(_ config: RoundConfig, _ role: RotatingRole, available: AvailableModels) -> RoundConfig {
        setting(config) { cfg in
            let last = switch role {
            case .reviewer: cfg.reviewerRotation.last?.choice
            case .integrator: cfg.integratorRotation.last
            case .polisher: cfg.polisherRotation.last
            }
            guard let last else { return }
            let agents = available.agents
            let next = (agents.firstIndex(of: last.agent).map { agents[($0 + 1) % agents.count] } ?? agents.first)
                .flatMap(available.choice(for:))
            guard let next, next.agent != last.agent else { return }
            switch role {
            case .reviewer: cfg.reviewers = cfg.reviewerRotation + [Slot(next)]
            case .integrator: cfg.integrators = cfg.integratorRotation + [next]
            case .polisher: cfg.polishers = cfg.polisherRotation + [next]
            }
        }
    }

    /// Takes entry `index` out; the rotation collapses to the one agent left, and the role's single
    /// field follows entry 0 (`RoundConfig.reviewers`).
    static func removingFromRotation(_ config: RoundConfig, _ role: RotatingRole, at index: Int) -> RoundConfig {
        reordering(config, role) { list in
            guard list.indices.contains(index), list.count > 1 else { return }
            list.remove(at: index)
        }
    }

    static func movingInRotation(_ config: RoundConfig, _ role: RotatingRole, from: Int, to: Int) -> RoundConfig {
        reordering(config, role) { list in
            guard list.indices.contains(from), list.indices.contains(to), from != to else { return }
            list.insert(list.remove(at: from), at: to)
        }
    }

    /// Back to the role's first agent alone.
    static func collapsingRotation(_ config: RoundConfig, _ role: RotatingRole) -> RoundConfig {
        reordering(config, role) { list in list = Array(list.prefix(1)) }
    }

    /// Edits the role's rotation as indices into its current list, then writes it back: a list of
    /// one or none is no rotation (nil), and the single field takes entry 0.
    private static func reordering(_ config: RoundConfig, _ role: RotatingRole, _ edit: (inout [Int]) -> Void) -> RoundConfig {
        setting(config) { cfg in
            var order = Array(0..<rotationCount(cfg, role))
            edit(&order)
            switch role {
            case .reviewer:
                let list = cfg.reviewerRotation
                let next = order.map { list[$0] }
                cfg.reviewers = next.count > 1 ? next : nil
                if let first = next.first { cfg.reviewer = first }
            case .integrator:
                let list = cfg.integratorRotation
                let next = order.map { list[$0] }
                cfg.integrators = next.count > 1 ? next : nil
                if let first = next.first { cfg.integrator = first }
            case .polisher:
                let list = cfg.polisherRotation
                let next = order.map { list[$0] }
                cfg.polishers = next.count > 1 ? next : nil
                if let first = next.first { cfg.polisher = first }
            }
        }
    }

    static func choice(for keyPath: SlotKeyPath, in config: RoundConfig) -> ModelChoice? {
        switch keyPath {
        case .drafter(let i): config.drafters.indices.contains(i) ? config.drafters[i].choice : nil
        case .synthesizer: config.synthesizer?.choice
        case .reviewer: config.reviewer?.choice
        case .crossReviewer: config.crossReviewer?.choice
        case .integrator: config.integrator
        case .encoder: config.encoder
        case .polisher: config.polisher
        case .reviewerEntry(let i): config.reviewerRotation.indices.contains(i) ? config.reviewerRotation[i].choice : nil
        case .integratorEntry(let i): config.integratorRotation.indices.contains(i) ? config.integratorRotation[i] : nil
        case .polisherEntry(let i): config.polisherRotation.indices.contains(i) ? config.polisherRotation[i] : nil
        }
    }

    /// A model choice in a config: a role's own, or the fallback it retries with.
    struct ChoiceSite: Hashable {
        var keyPath: SlotKeyPath
        var isFallback = false
    }

    static func choice(at site: ChoiceSite, in config: RoundConfig) -> ModelChoice? {
        site.isFallback ? fallback(for: site.keyPath, in: config) : choice(for: site.keyPath, in: config)
    }

    static func updatingChoice(_ config: RoundConfig, at site: ChoiceSite, _ mutate: (inout ModelChoice) -> Void) -> RoundConfig {
        guard site.isFallback else { return updatingChoice(config, at: site.keyPath, mutate) }
        guard var fallback = fallback(for: site.keyPath, in: config) else { return config }
        mutate(&fallback)
        return updatingFallback(config, at: site.keyPath, to: fallback)
    }

    static func fallback(for keyPath: SlotKeyPath, in config: RoundConfig) -> ModelChoice? {
        switch keyPath {
        case .drafter(let i): config.drafters.indices.contains(i) ? config.drafters[i].fallback : nil
        case .synthesizer: config.synthesizer?.fallback
        case .reviewer: config.reviewer?.fallback
        case .reviewerEntry(let i): config.reviewerRotation.indices.contains(i) ? config.reviewerRotation[i].fallback : nil
        case .crossReviewer, .integrator, .encoder, .polisher, .integratorEntry, .polisherEntry: nil
        }
    }

    /// Only `Slot`-backed seats carry a fallback field at all — `integrator`/`encoder`/
    /// `polisher` are bare `ModelChoice`, with no availability retry modeled for them.
    /// `crossReviewer` is a `Slot` too but never offers one: its fallback would be the
    /// primary's family, and a same-family "cross-check" isn't independent (`RoundConfig`'s
    /// own doc comment on `crossReviewer`).
    static func supportsFallback(_ keyPath: SlotKeyPath) -> Bool {
        switch keyPath {
        case .drafter, .synthesizer, .reviewer, .reviewerEntry: true
        case .crossReviewer, .integrator, .encoder, .polisher, .integratorEntry, .polisherEntry: false
        }
    }

    static func updatingChoice(_ config: RoundConfig, at keyPath: SlotKeyPath, _ mutate: (inout ModelChoice) -> Void) -> RoundConfig {
        setting(config) { cfg in
            switch keyPath {
            case .drafter(let i):
                guard cfg.drafters.indices.contains(i) else { return }
                mutate(&cfg.drafters[i].choice)
            case .synthesizer:
                guard cfg.synthesizer != nil else { return }
                mutate(&cfg.synthesizer!.choice)
            case .reviewer:
                guard cfg.reviewer != nil else { return }
                mutate(&cfg.reviewer!.choice)
                if cfg.reviewers?.isEmpty == false { cfg.reviewers![0] = cfg.reviewer! }
            case .crossReviewer:
                guard cfg.crossReviewer != nil else { return }
                mutate(&cfg.crossReviewer!.choice)
            case .integrator:
                mutate(&cfg.integrator)
                if cfg.integrators?.isEmpty == false { cfg.integrators![0] = cfg.integrator }
            case .encoder:
                mutate(&cfg.encoder)
            case .polisher:
                guard cfg.polisher != nil else { return }
                mutate(&cfg.polisher!)
                if cfg.polishers?.isEmpty == false { cfg.polishers![0] = cfg.polisher! }
            case .reviewerEntry(let i):
                guard cfg.reviewers?.indices.contains(i) == true else { return }
                mutate(&cfg.reviewers![i].choice)
            case .integratorEntry(let i):
                guard cfg.integrators?.indices.contains(i) == true else { return }
                mutate(&cfg.integrators![i])
            case .polisherEntry(let i):
                guard cfg.polishers?.indices.contains(i) == true else { return }
                mutate(&cfg.polishers![i])
            }
        }
    }

    static func updatingFallback(_ config: RoundConfig, at keyPath: SlotKeyPath, to fallback: ModelChoice?) -> RoundConfig {
        setting(config) { cfg in
            switch keyPath {
            case .drafter(let i):
                guard cfg.drafters.indices.contains(i) else { return }
                cfg.drafters[i].fallback = fallback
            case .synthesizer:
                cfg.synthesizer?.fallback = fallback
            case .reviewer:
                cfg.reviewer?.fallback = fallback
                if cfg.reviewers?.isEmpty == false, let reviewer = cfg.reviewer { cfg.reviewers![0] = reviewer }
            case .reviewerEntry(let i):
                guard cfg.reviewers?.indices.contains(i) == true else { return }
                cfg.reviewers![i].fallback = fallback
            case .crossReviewer, .integrator, .encoder, .polisher, .integratorEntry, .polisherEntry:
                break // crossReviewer never offers a fallback control; integrator/encoder/polisher have no field to set.
            }
        }
    }

    /// Moves a role (or its fallback) to `model` on `agent`: the effort follows the model, and the
    /// role's own account is kept only while the agent stays the same — an account belongs to one
    /// agent (`AvailableModels.selecting`).
    static func selecting(_ config: RoundConfig, at site: ChoiceSite, agent: AgentID, model: String,
                          available: AvailableModels) -> RoundConfig {
        let next = available.selecting(agent: agent, model: model, from: choice(at: site, in: config))
        if site.isFallback { return updatingFallback(config, at: site.keyPath, to: next) }
        return updatingChoice(config, at: site.keyPath) { $0 = next }
    }

    /// The fallback Picker's one non-"None" option: the first available model of ANOTHER family
    /// than the seat's, in `AgentID.planningOrder` order — so codex still falls back to claude and
    /// claude to codex, and a gemini seat falls back to the first of those present. Nil on a
    /// single-harness machine, where there is no other model.
    static func otherModel(for choice: ModelChoice, available: AvailableModels) -> ModelChoice? {
        available.agents.first { $0 != choice.agent }.flatMap(available.choice(for:))
    }
}
