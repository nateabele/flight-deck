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

/// Lets the human tune a chosen preset's expanded `RoundConfig` before shaping starts. Its home
/// is the detail pane's inspector (spec §9): the awaiting-choice body shows only `summary` and
/// an Edit in Inspector button, since a five-column grid pushed the way forward off screen.
struct RoundConfigEditor: View {
    let preset: Preset
    @Binding var config: RoundConfig
    let available: AvailableModels

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
                            modelField(for: row.keyPath)
                            effortPicker(for: row.keyPath).fixedSize()
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

    private func modelField(for keyPath: SlotKeyPath) -> some View {
        TextField("Model", text: modelBinding(for: keyPath))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }

    private func effortPicker(for keyPath: SlotKeyPath) -> some View {
        Picker("Effort", selection: effortBinding(for: keyPath)) {
            ForEach(Self.effortChoices, id: \.self) { effort in
                Text(effort).tag(effort)
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
    /// bare `String` that would accept it.
    static let effortChoices = ["low", "medium", "high", "xhigh", "max"]

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
    /// with a claude model name that codex has never heard of.
    static func switchingHarness(_ config: RoundConfig, at keyPath: SlotKeyPath, to harness: Harness, available: AvailableModels) -> RoundConfig {
        let replacement = available.choice(for: harness) ?? ModelChoice(harness: harness, model: "", effort: "high")
        return updatingChoice(config, at: keyPath) { $0 = replacement }
    }

    /// Harness Pickers only ever offer harnesses actually installed — an unavailable harness
    /// in the list would let the human pick a model no adapter can run.
    static func harnesses(in available: AvailableModels) -> [Harness] {
        var result: [Harness] = []
        if available.codex != nil { result.append(.codex) }
        if available.claude != nil { result.append(.claude) }
        return result
    }

    /// The fallback Picker's one non-"None" option: whichever available model ISN'T the
    /// seat's current choice. Nil on a single-harness machine, where there is no other model.
    static func otherModel(for choice: ModelChoice, available: AvailableModels) -> ModelChoice? {
        choice.harness == .codex ? available.claude : available.codex
    }
}

private extension AvailableModels {
    func choice(for harness: Harness) -> ModelChoice? {
        switch harness {
        case .codex: codex
        case .claude: claude
        }
    }
}
