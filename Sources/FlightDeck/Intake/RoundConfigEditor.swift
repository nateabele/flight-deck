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
}

/// One non-built-in account a planning agent can bill, as the Rounds editor offers it. Built from
/// preferences by `options(from:)`; the built-in account is never listed, because nil already
/// means it (`ModelChoice.account`).
struct PlanningAccountOption: Equatable {
    var ref: AgentAccountRef
    var name: String

    /// Each harness's live, non-built-in accounts, in preferences order. A removed account is
    /// left out — it is not something to pick — and an agent with no harness (none today) too.
    static func options(from accounts: [AgentAccount]) -> [Harness: [PlanningAccountOption]] {
        var out: [Harness: [PlanningAccountOption]] = [:]
        for account in accounts where !account.isRemoved && !account.isBuiltIn {
            guard let harness = Harness(rawValue: account.agent.rawValue) else { continue }
            out[harness, default: []].append(PlanningAccountOption(
                ref: AgentAccountRef(id: account.id.uuidString, home: account.home), name: account.displayName))
        }
        return out
    }
}

/// Lets the human tune a chosen preset's expanded `RoundConfig` before shaping starts. Its home
/// is the detail pane's inspector (spec §9): the awaiting-choice body shows only `summary` and
/// an Edit in Inspector button, since a five-column grid pushed the way forward off screen.
struct RoundConfigEditor: View {
    let preset: Preset
    @Binding var config: RoundConfig
    let available: AvailableModels
    /// Each harness's pickable accounts (`PlanningAccountOption.options`). Empty hides every
    /// account picker, which is the whole editor on a machine with only built-in logins.
    var accounts: [Harness: [PlanningAccountOption]] = [:]
    /// codex's own `model/list`, when routing has already fetched it this launch — never
    /// fetched from here, since that spawns an app-server.
    var codexListedModels: [String] = []

    var body: some View {
        // The whole inspector panel, under a plain title: a disclosure here would be a second
        // way to hide what the panel was opened to show.
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.label(preset: preset, config: config)).font(.headline)
            stackedSlots
            Divider()
            capsForm
        }
    }

    /// One block per seat, its controls on two lines. A five-column grid needed ~530 pt, and an
    /// inspector column is narrower than that — the Model field collapsed to nothing and the
    /// Fallback picker ran off the panel's edge.
    private var stackedSlots: some View {
        let rows = Self.slots(of: config)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.element.keyPath) { index, row in
                if let choice = Self.choice(for: row.keyPath, in: config) {
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // `.capitalized` title-cases every word, which turns "cross-check
                            // agent" into "Cross-Check Agent" — `sentenceCase` only raises the
                            // first letter, so the role reads as the phrase `UIText` intends.
                            Text(UIText.sentenceCase(UIText.roleName(row.role))).font(.callout.weight(.semibold))
                            if let persona = row.persona, persona != .general {
                                Text(persona.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            harnessPicker(for: row.keyPath).fixedSize()
                            modelField(for: row.keyPath, harness: choice.harness)
                            if !Self.effortChoices(for: choice.harness).isEmpty {
                                effortPicker(for: row.keyPath, harness: choice.harness).fixedSize()
                            }
                        }
                        if let options = accounts[choice.harness], !options.isEmpty {
                            HStack(spacing: 8) {
                                Text("Account").foregroundStyle(.secondary)
                                accountPicker(for: row.keyPath, choice: choice, options: options).fixedSize()
                            }
                            .font(.callout)
                        }
                        if Self.supportsFallback(row.keyPath) {
                            HStack(spacing: 8) {
                                Text("Fallback").foregroundStyle(.secondary)
                                fallbackPicker(for: row.keyPath, choice: choice).fixedSize()
                            }
                            .font(.callout)
                        }
                        // Only reached once the crossReviewer row itself is showing (policy
                        // not off), so the caption never appears while the picker reads "Off".
                        if row.keyPath == .crossReviewer, Self.crossCheckSameFamily(config) {
                            Text("Same family as the reviewer, so rounds won't cross-check.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // Directly under the reviewer row (spec: coverage §8) rather than folded into
                // its own block above — the policy can be live with no crossReviewer row yet
                // showing (nothing seeded), so it can't be gated on `Self.choice(for:)` the way
                // every other row is.
                if row.keyPath == .reviewer, config.reviewer != nil {
                    crossCheckPicker
                }
            }
        }
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

    private func harnessPicker(for keyPath: SlotKeyPath) -> some View {
        Picker("Harness", selection: harnessBinding(for: keyPath)) {
            ForEach(Self.harnesses(in: available), id: \.self) { harness in
                Text(harness.rawValue).tag(harness)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// Free text, because every CLI also takes a full model name — with the profile's known
    /// models one click away, so `fable` is offered here as it is in Settings and routing.
    private func modelField(for keyPath: SlotKeyPath, harness: Harness) -> some View {
        let suggestions = Self.modelSuggestions(for: harness, codexListed: codexListedModels)
        return HStack(spacing: 2) {
            TextField("Model", text: modelBinding(for: keyPath))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { model in
                        Button(model) { config = Self.updatingChoice(config, at: keyPath) { $0.model = model } }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Known models")
            }
        }
    }

    private func effortPicker(for keyPath: SlotKeyPath, harness: Harness) -> some View {
        Picker("Effort", selection: effortBinding(for: keyPath)) {
            ForEach(Self.effortChoices(for: harness), id: \.self) { effort in
                Text(effort).tag(effort)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// "Built-in account" or one of this harness's accounts from preferences. The selection is
    /// the account's id rather than the ref, so a relocated home still shows as selected.
    private func accountPicker(for keyPath: SlotKeyPath, choice: ModelChoice, options: [PlanningAccountOption]) -> some View {
        Picker("Account", selection: Binding<String?>(
            get: { Self.choice(for: keyPath, in: config)?.account?.id },
            set: { id in config = Self.settingAccount(config, at: keyPath, to: id, options: options) }
        )) {
            ForEach(Self.accountChoices(for: choice, options: options), id: \.id) { entry in
                Text(entry.label).tag(entry.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// "none" or the other available model. `ModelChoice` isn't `Hashable` (its `.effort` is a
    /// free-text `String` that never needs set/dictionary membership elsewhere), so the Picker's
    /// selection is the two-way "has a fallback at all" toggle ("none" or the other model), not
    /// the choice itself.
    private func fallbackPicker(for keyPath: SlotKeyPath, choice: ModelChoice) -> some View {
        let other = Self.otherModel(for: choice, available: available)
        return Picker("Fallback", selection: fallbackBinding(for: keyPath, other: other)) {
            Text("none").tag(false)
            if let other {
                Text("\(other.harness.rawValue) \(other.model)").tag(true)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// The caps/toggle/default-play controls below the seats, as a compact label-left
    /// two-column form rather than each control spelling its own label out in full.
    private var capsForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Refinement cap").foregroundStyle(.secondary)
                Stepper("\(config.refinementCap)", value: refinementCapBinding, in: 0...12)
            }
            // Polish, fresh eyes and dedup are all seated by the polisher; with none, these
            // controls would promise rounds the planner never runs (`TapePlanner.sequence`).
            GridRow {
                Text("Polish cap").foregroundStyle(.secondary)
                Stepper("\(config.polishCap)", value: polishCapBinding, in: 0...12)
                    .disabled(!Self.polishControlsEnabled(config))
            }
            .help(Self.polishControlsHelp(config))
            GridRow {
                Text("Fresh eyes + dedup").foregroundStyle(.secondary)
                Toggle("", isOn: freshEyesBinding).labelsHidden()
                    .disabled(!Self.polishControlsEnabled(config))
            }
            .help(Self.polishControlsHelp(config))
            GridRow {
                Text("Default play").foregroundStyle(.secondary)
                Picker("", selection: defaultPlayBinding) {
                    Text("Step").tag(PlayMode.step)
                    Text("Next major").tag(PlayMode.nextMajor)
                    Text("To review").tag(PlayMode.toReview)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Bindings (route every edit through `setting`, which flags `customized`)

    private func harnessBinding(for keyPath: SlotKeyPath) -> Binding<Harness> {
        Binding(
            get: { Self.choice(for: keyPath, in: config)?.harness ?? .codex },
            set: { config = Self.switchingHarness(config, at: keyPath, to: $0, available: available) }
        )
    }

    private func modelBinding(for keyPath: SlotKeyPath) -> Binding<String> {
        Binding(
            get: { Self.choice(for: keyPath, in: config)?.model ?? "" },
            set: { newValue in config = Self.updatingChoice(config, at: keyPath) { $0.model = newValue } }
        )
    }

    private func effortBinding(for keyPath: SlotKeyPath) -> Binding<String> {
        Binding(
            get: { Self.choice(for: keyPath, in: config)?.effort ?? "high" },
            set: { newValue in config = Self.updatingChoice(config, at: keyPath) { $0.effort = newValue } }
        )
    }

    private func fallbackBinding(for keyPath: SlotKeyPath, other: ModelChoice?) -> Binding<Bool> {
        Binding(
            get: { Self.fallback(for: keyPath, in: config) != nil },
            set: { hasFallback in config = Self.updatingFallback(config, at: keyPath, to: hasFallback ? other : nil) }
        )
    }

    private var crossCheckBinding: Binding<CrossCheckPolicy> {
        Binding(
            get: { config.crossCheck ?? .off },
            set: { newValue in config = Self.settingCrossCheck(config, to: newValue, available: available) }
        )
    }

    private var refinementCapBinding: Binding<Int> {
        Binding(get: { config.refinementCap }, set: { newValue in config = Self.setting(config) { $0.refinementCap = newValue } })
    }

    private var polishCapBinding: Binding<Int> {
        Binding(get: { config.polishCap }, set: { newValue in config = Self.setting(config) { $0.polishCap = newValue } })
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

    /// The refine rounds that would cross-check at the current caps — `TapePlanner`'s own
    /// first/last/every rule, but over `refinementCap` alone: the editor has no tape (and so
    /// no `extraRefinement`) to fold in. Empty whenever `config.crossChecks` is false (`.off`,
    /// no crossReviewer yet, or a same-family pairing that can't cross-check anything).
    static func crossCheckRounds(_ config: RoundConfig) -> [Int] {
        guard config.crossChecks, let policy = config.crossCheck, config.refinementCap > 0 else { return [] }
        let total = config.refinementCap
        return (1...total).filter { round in
            switch policy {
            case .off: false
            case .firstAndLast: round == 1 || round == total
            case .every: true
            }
        }
    }

    /// Whether the crossReviewer picked the same family as the reviewer — the caption under its
    /// row explains why a live policy still won't cross-check anything.
    static func crossCheckSameFamily(_ config: RoundConfig) -> Bool {
        guard let reviewer = config.reviewer, let crossReviewer = config.crossReviewer else { return false }
        return ModelFamily(reviewer.choice.harness) == ModelFamily(crossReviewer.choice.harness)
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
    static func effortChoices(for harness: Harness) -> [String] {
        AgentProfiles.profile(for: harness).modelCatalog.effortValues
    }

    /// The models the model field's menu offers for `harness`: its profile's static aliases,
    /// then codex's runtime list when routing has one cached, else the profile's default —
    /// never empty for a harness with a catalog, never a duplicate.
    static func modelSuggestions(for harness: Harness, codexListed: [String] = []) -> [String] {
        let catalog = AgentProfiles.profile(for: harness).modelCatalog
        var out: [String] = []
        for model in catalog.aliases + (harness == .codex ? codexListed : []) where !out.contains(model) {
            out.append(model)
        }
        if out.isEmpty, !catalog.defaultPlanningModel.isEmpty { out = [catalog.defaultPlanningModel] }
        return out
    }

    /// The account picker's rows: the built-in account (id nil) first, then each option. A
    /// seat still bound to an account that has since been removed keeps a row of its own, so
    /// the picker never shows a selection it has no row for — and re-picking is a choice.
    static func accountChoices(for choice: ModelChoice, options: [PlanningAccountOption]) -> [(id: String?, label: String)] {
        var rows: [(id: String?, label: String)] = [(nil, "Built-in account")]
        rows += options.map { ($0.ref.id, $0.name) }
        if let bound = choice.account, !options.contains(where: { $0.ref.id == bound.id }) {
            rows.append((bound.id, "Removed account"))
        }
        return rows
    }

    /// Binds the seat to the account with this id, from `options` — its CURRENT home, so a
    /// re-pick after a relocate picks the new directory up. nil, or an id no longer offered
    /// (the "Removed account" row), leaves the binding as nil and as-is respectively.
    static func settingAccount(_ config: RoundConfig, at keyPath: SlotKeyPath, to id: String?,
                               options: [PlanningAccountOption]) -> RoundConfig {
        guard let id else { return updatingChoice(config, at: keyPath) { $0.account = nil } }
        guard let option = options.first(where: { $0.ref.id == id }) else { return config }
        return updatingChoice(config, at: keyPath) { $0.account = option.ref }
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

    /// Applies `mutate` to a copy of `config` and marks it customized — the one path every
    /// field edit in the view routes through, so "edited anything" and "labeled customized"
    /// can never drift apart.
    static func setting(_ config: RoundConfig, _ mutate: (inout RoundConfig) -> Void) -> RoundConfig {
        var next = config
        mutate(&next)
        next.customized = true
        return next
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
        }
    }

    static func fallback(for keyPath: SlotKeyPath, in config: RoundConfig) -> ModelChoice? {
        switch keyPath {
        case .drafter(let i): config.drafters.indices.contains(i) ? config.drafters[i].fallback : nil
        case .synthesizer: config.synthesizer?.fallback
        case .reviewer: config.reviewer?.fallback
        case .crossReviewer, .integrator, .encoder, .polisher: nil
        }
    }

    /// Only `Slot`-backed seats carry a fallback field at all — `integrator`/`encoder`/
    /// `polisher` are bare `ModelChoice`, with no availability retry modeled for them.
    /// `crossReviewer` is a `Slot` too but never offers one: its fallback would be the
    /// primary's family, and a same-family "cross-check" isn't independent (`RoundConfig`'s
    /// own doc comment on `crossReviewer`).
    static func supportsFallback(_ keyPath: SlotKeyPath) -> Bool {
        switch keyPath {
        case .drafter, .synthesizer, .reviewer: true
        case .crossReviewer, .integrator, .encoder, .polisher: false
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
            case .crossReviewer:
                guard cfg.crossReviewer != nil else { return }
                mutate(&cfg.crossReviewer!.choice)
            case .integrator:
                mutate(&cfg.integrator)
            case .encoder:
                mutate(&cfg.encoder)
            case .polisher:
                guard cfg.polisher != nil else { return }
                mutate(&cfg.polisher!)
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
            case .crossReviewer, .integrator, .encoder, .polisher:
                break // crossReviewer never offers a fallback control; integrator/encoder/polisher have no field to set.
            }
        }
    }

    /// Switching a seat's harness resets model AND effort to that harness's default from
    /// `available` — leaving the old model string in place would pair e.g. codex's harness
    /// with a claude model name that codex has never heard of. The account resets to built-in
    /// with them: a claude account's home means nothing to codex.
    static func switchingHarness(_ config: RoundConfig, at keyPath: SlotKeyPath, to harness: Harness, available: AvailableModels) -> RoundConfig {
        let replacement = available.choice(for: harness) ?? ModelChoice(harness: harness, model: "", effort: "high")
        return updatingChoice(config, at: keyPath) { $0 = replacement }
    }

    /// Harness Pickers only ever offer harnesses actually installed — an unavailable harness
    /// in the list would let the human pick a model no adapter can run.
    static func harnesses(in available: AvailableModels) -> [Harness] {
        available.harnesses
    }

    /// The fallback Picker's one non-"None" option: whichever available model ISN'T the
    /// seat's current choice. Nil on a single-harness machine, where there is no other model.
    static func otherModel(for choice: ModelChoice, available: AvailableModels) -> ModelChoice? {
        choice.harness == .codex ? available.claude : available.codex
    }
}
