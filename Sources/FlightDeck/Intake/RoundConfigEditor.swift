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
    case integrator
    case encoder
    case polisher
}

/// Lets the human tune a chosen preset's expanded `RoundConfig` before shaping starts — the
/// "Rounds" disclosure under the fidelity picker in `.awaitingChoice`. Task 11 wires this into
/// `IntakeDetailView` and the Start button; this file only needs to compile and render on its
/// own, against the `RoundConfig`/`AvailableModels` shapes Task 10 already landed.
struct RoundConfigEditor: View {
    let preset: Preset
    @Binding var config: RoundConfig
    let available: AvailableModels

    /// Starts open: choosing anything above Bead means the human is about to look at (or
    /// tune) exactly this, not something they need to go find behind a second click.
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(Self.label(preset: preset, config: config), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.slots(of: config), id: \.keyPath) { row in
                    slotRow(role: row.role, persona: row.persona, keyPath: row.keyPath)
                }
                Divider()
                Stepper("Refinement cap: \(config.refinementCap)", value: refinementCapBinding, in: 0...12)
                Stepper("Polish cap: \(config.polishCap)", value: polishCapBinding, in: 0...12)
                Toggle("Fresh eyes + dedup", isOn: freshEyesBinding)
                Picker("Default play", selection: defaultPlayBinding) {
                    Text("Step").tag(PlayMode.step)
                    Text("Next major").tag(PlayMode.nextMajor)
                    Text("To review").tag(PlayMode.toReview)
                }
                .pickerStyle(.menu)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func slotRow(role: String, persona: DrafterPersona?, keyPath: SlotKeyPath) -> some View {
        // Every row in `slots(of:)` names a seat that's actually filled (it skips nil
        // synthesizer/reviewer/polisher), so this only returns nil if config and keyPath have
        // gone out of sync between render passes — nothing to show mid-edit.
        if let choice = Self.choice(for: keyPath, in: config) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(role.capitalized).font(.callout.weight(.semibold))
                    // `.general` is the only persona a single-drafter round ever uses and
                    // says nothing a Sketch/Feature-plan reader doesn't already know.
                    if let persona, persona != .general {
                        Text(persona.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Picker("Harness", selection: harnessBinding(for: keyPath)) {
                        ForEach(Self.harnesses(in: available), id: \.self) { harness in
                            Text(harness.rawValue).tag(harness)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
                    TextField("Model", text: modelBinding(for: keyPath))
                        .textFieldStyle(.roundedBorder)
                    Picker("Effort", selection: effortBinding(for: keyPath)) {
                        ForEach(Self.effortChoices, id: \.self) { effort in
                            Text(effort).tag(effort)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
                }
                if Self.supportsFallback(keyPath) {
                    let other = Self.otherModel(for: choice, available: available)
                    // `ModelChoice` isn't `Hashable` (its `.effort` is a free-text `String`
                    // that never needs set/dictionary membership elsewhere), so the Picker's
                    // selection is the two-way "has a fallback at all" toggle the brief
                    // actually asks for ("none" or the other model), not the choice itself.
                    Picker("Fallback", selection: fallbackBinding(for: keyPath, other: other)) {
                        Text("None").tag(false)
                        if let other {
                            Text("\(other.harness.rawValue) \(other.model)").tag(true)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            .padding(.vertical, 2)
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

    private var refinementCapBinding: Binding<Int> {
        Binding(get: { config.refinementCap }, set: { newValue in config = Self.setting(config) { $0.refinementCap = newValue } })
    }

    private var polishCapBinding: Binding<Int> {
        Binding(get: { config.polishCap }, set: { newValue in config = Self.setting(config) { $0.polishCap = newValue } })
    }

    private var freshEyesBinding: Binding<Bool> {
        Binding(get: { config.freshEyesAndDedup }, set: { newValue in config = Self.setting(config) { $0.freshEyesAndDedup = newValue } })
    }

    private var defaultPlayBinding: Binding<PlayMode> {
        Binding(get: { config.defaultPlay }, set: { newValue in config = Self.setting(config) { $0.defaultPlay = newValue } })
    }

    // MARK: - Pure helpers (also covered directly by RoundConfigEditorTests)

    /// "<Preset>, customized" once any field has been edited — the label the brief specifies
    /// for the disclosure's own title.
    static func label(preset: Preset, config: RoundConfig) -> String {
        let base = presetLabel(preset)
        return config.customized ? "\(base), customized" : base
    }

    private static func presetLabel(_ preset: Preset) -> String {
        switch preset {
        case .bead: "Bead"
        case .sketch: "Sketch"
        case .featurePlan: "Feature plan"
        case .fullPlan: "Full plan"
        }
    }

    /// `ultra` enables delegation and isn't Pro, so it's excluded even though `effort` is a
    /// bare `String` that would accept it.
    static let effortChoices = ["low", "medium", "high", "xhigh", "max"]

    /// One row per filled seat, in the fixed order the round actually runs: every drafter,
    /// then synthesizer, reviewer, integrator, encoder, polisher. Skips synthesizer/reviewer/
    /// polisher when the preset has none, rather than emitting a row with nothing to bind to.
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
        case .integrator, .encoder, .polisher: nil
        }
    }

    /// Only `Slot`-backed seats carry a fallback field at all — `integrator`/`encoder`/
    /// `polisher` are bare `ModelChoice`, with no availability retry modeled for them.
    static func supportsFallback(_ keyPath: SlotKeyPath) -> Bool {
        switch keyPath {
        case .drafter, .synthesizer, .reviewer: true
        case .integrator, .encoder, .polisher: false
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
            case .integrator, .encoder, .polisher:
                break // No fallback field to set on a bare ModelChoice seat.
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
