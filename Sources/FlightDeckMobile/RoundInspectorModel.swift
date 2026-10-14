import FleetKit
import Foundation

/// The read-only Rounds inspector, as decisions (MOBILE-UI: a decision reachable without SwiftUI
/// is one a test can run). The phone counterpart of the Mac's Rounds inspector: every agent a
/// round configuration runs, stage by stage, then the caps and the default play. Wording follows
/// the Mac's `RoundConfigEditor`, with "agent" for what the Mac's code calls a seat.
struct RoundInspectorModel: Equatable {
    struct Fact: Equatable {
        let label: String
        let value: String
    }

    struct Agent: Equatable, Identifiable {
        let id: String
        /// The agent's wire id ("claude", "codex"…), for its icon (`AgentIcon`).
        let agent: String
        let role: String
        /// The drafter's angle ("arbiter", "realist"); nil for `general`, which says nothing.
        let persona: String?
        /// "Codex · gpt-6-sol · high".
        let line: String
        /// "Falls back to Claude · opus · high", when the agent has one.
        let fallback: String?
        /// The fallback's wire id, for its icon.
        let fallbackAgent: String?
        /// The agents this role takes in turn, round after round, in order — empty for a role
        /// with one agent. `agent` and `line` then describe the first.
        var rotation: [Alternate] = []
    }

    /// One agent in a rotating role.
    struct Alternate: Equatable, Identifiable {
        let id: String
        /// The wire id, for its icon.
        let agent: String
        /// The display name, "Claude".
        let name: String
        /// "Claude · opus · high".
        let line: String
    }

    struct Stage: Equatable, Identifiable {
        let id: String
        let title: String
        let agents: [Agent]
        let facts: [Fact]
    }

    let title: String
    let stages: [Stage]
    /// What belongs to no stage: the default play.
    let settings: [Fact]

    static func make(preset: String?, config: WireRoundConfig) -> RoundInspectorModel {
        let base = IntakeRowStyle.presetName(preset) ?? "Rounds"
        return RoundInspectorModel(
            title: config.customized ? "\(base), customized" : base,
            stages: stages(config),
            settings: [Fact(label: "Default play", value: playName(config.defaultPlay))])
    }

    /// Stages in run order. A stage with no agent (Sketch has no polisher or synthesizer) is
    /// left out rather than drawn empty, as the Mac's inspector does. The integrator sits under
    /// Refine, the stage it runs every round of.
    private static func stages(_ c: WireRoundConfig) -> [Stage] {
        var stages: [Stage] = []
        if !c.drafters.isEmpty {
            stages.append(Stage(id: "draft", title: "Draft",
                                agents: c.drafters.enumerated().map { agent("drafter\($0.offset)", "Drafter", $0.element) }, facts: []))
        }
        if let s = c.synthesizer {
            stages.append(Stage(id: "synthesis", title: "Synthesis", agents: [agent("synthesizer", "Synthesizer", s)], facts: []))
        }
        var refine: [Agent] = []
        var refineFacts: [Fact] = []
        if let reviewer = c.reviewer {
            refine.append(agent("reviewer", "Reviewer", reviewer, rotation: c.reviewers))
            // The Mac shows the cross-check agent only while the policy is on.
            if let policy = c.crossCheck, policy != "off", let cross = c.crossReviewer {
                refine.append(agent("crossReviewer", "Cross-check agent", cross))
            }
            refineFacts.append(Fact(label: "Rounds", value: "\(c.refinementCap)"))
            refineFacts.append(Fact(label: "Cross-check", value: crossCheckName(c.crossCheck)))
        }
        refine.append(agent("integrator", "Integrator", c.integrator, rotation: c.integrators))
        stages.append(Stage(id: "refine", title: "Refine", agents: refine, facts: refineFacts))
        stages.append(Stage(id: "encode", title: "Encode", agents: [agent("encoder", "Encoder", c.encoder)], facts: []))
        if let polisher = c.polisher {
            stages.append(Stage(id: "polish", title: "Polish", agents: [agent("polisher", "Polisher", polisher, rotation: c.polishers)], facts: [
                Fact(label: "Rounds", value: "\(c.polishCap)"),
                Fact(label: "Fresh eyes + dedup", value: c.freshEyesAndDedup ? "On" : "Off"),
            ]))
        }
        return stages
    }

    /// `rotation` is the role's agents in turn when the Mac sent them; one entry (or none) is
    /// the single agent, as an older Mac sends it. A rotation reads "Alternates: Claude → Gemini
    /// → Codex" with each agent's icon, and its first agent's fallback is not shown: every entry
    /// of a reviewer's rotation has its own.
    private static func agent(_ id: String, _ role: String, _ seat: WireSeat, rotation: [WireSeat]? = nil) -> Agent {
        let persona = seat.persona.flatMap { $0 == "general" ? nil : $0 }
        guard let rotation, rotation.count > 1 else {
            return Agent(id: id, agent: seat.choice.agent, role: role, persona: persona,
                         line: describe(seat.choice), fallback: seat.fallback.map { "Falls back to \(describe($0))" },
                         fallbackAgent: seat.fallback?.agent)
        }
        let names = rotation.map { agentName($0.choice) }
        return Agent(id: id, agent: rotation[0].choice.agent, role: role, persona: persona,
                     line: "Alternates: " + names.joined(separator: " → "), fallback: nil, fallbackAgent: nil,
                     rotation: rotation.enumerated().map { i, seat in
                         Alternate(id: "\(id)\(i)", agent: seat.choice.agent, name: names[i], line: describe(seat.choice))
                     })
    }

    /// The agent as a person reads it; a Mac that sends no name gets the id capitalized.
    private static func agentName(_ c: WireModelChoice) -> String {
        c.agentName ?? c.agent.prefix(1).uppercased() + c.agent.dropFirst()
    }

    /// "Claude > Opus 5.5 · high", then "· Work pool" when the role holds its own account. A Mac
    /// that sends no `modelName` shows the model as it came; one that sends no `agentName` shows
    /// the agent capitalized, never as the raw id.
    static func describe(_ c: WireModelChoice) -> String {
        let agent = agentName(c)
        var model = c.modelName ?? c.model
        // "Gemini > 3.8 Flash (High)": a name that already starts with its agent's says it once,
        // as the Mac's `AvailableModels.modelLabel` does.
        if model.hasPrefix(agent + " ") { model.removeFirst(agent.count + 1) }
        let head = model.isEmpty ? agent : "\(agent) > \(model)"
        return [head, c.effort, c.account.map { "Account: \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// An unknown word from a newer Mac shows as it came.
    static func crossCheckName(_ raw: String?) -> String {
        switch raw {
        case nil, "off": "Off"
        case "firstAndLast": "First and last"
        case "every": "Every round"
        default: raw ?? "Off"
        }
    }

    static func playName(_ raw: String) -> String {
        switch raw {
        case "step": "Step"
        case "nextMajor": "Next major"
        case "toReview": "To review"
        default: raw
        }
    }
}

/// The fidelity chooser on the intake screen: what to offer, and what to say before it costs
/// anything.
struct FidelityOption: Equatable, Identifiable {
    var id: String { preset }
    let preset: String
    let name: String
    let recommended: Bool
    /// "2 drafters · refine ×3 · polish ×2", or what Single task does.
    let summary: String
    /// Whether the Mac sent a configuration to inspect for this fidelity.
    let hasRounds: Bool
    /// The phone edited this fidelity's rounds; Start sends the edit.
    var edited = false
}

enum FidelityChooser {
    /// `nil` unless the Mac said it accepts the choice (`choose`) and sent the fidelities: an
    /// older Mac drops the socket on `intake.choose`, so the phone must not offer what it
    /// cannot send. The screen then says to choose on the Mac.
    static func options(detail: WireIntakeDetail, drafts: [String: RoundDraft] = [:]) -> [FidelityOption]? {
        guard detail.choose == true, detail.steer == true,
              let choice = detail.choice, let presets = choice.presets, !presets.isEmpty,
              ["awaitingChoice", "parked"].contains(detail.summary.state) else { return nil }
        return presets.map { option in
            // A fidelity the phone edited reads as edited: the summary is what Start will run.
            let draft = drafts[option.preset].flatMap { RoundEditing.differs($0) ? $0 : nil }
            return FidelityOption(
                preset: option.preset, name: IntakeRowStyle.presetName(option.preset) ?? option.preset,
                recommended: option.preset == choice.recommended,
                summary: (draft?.config ?? option.config).map(summary) ?? "Writes one task straight from triage, with no planning rounds.",
                hasRounds: option.config != nil, edited: draft != nil)
        }
    }

    static func summary(_ c: WireRoundConfig) -> String {
        var parts = ["\(c.drafters.count) drafter\(c.drafters.count == 1 ? "" : "s")"]
        if c.reviewer != nil, c.refinementCap > 0 { parts.append("refine ×\(c.refinementCap)") }
        if c.polisher != nil, c.polishCap > 0 { parts.append("polish ×\(c.polishCap)") }
        return parts.joined(separator: " · ")
    }

    /// Asked before sending: a planning fidelity starts paid agent rounds on the Mac.
    static func confirmation(for option: FidelityOption) -> (title: String, message: String, button: String) {
        let message = option.hasRounds
            ? "This starts paid agent rounds on your Mac, with the agents shown under Rounds."
            : "This runs an agent on your Mac to write the task."
        return ("Start with \(option.name)?", message, "Start")
    }
}

/// Whether the inspector edits, and what it edits: the Mac's config for the fidelity or the running
/// intake, with the phone's unsent edit over it.
struct RoundEditing: Equatable {
    var editor: RoundEditor
    let key: String
    /// What the Mac holds now.
    let current: WireRoundConfig
    /// What the edit was made from: `current`, until the phone edits.
    let base: WireRoundConfig

    /// The draft's key in `IntakeDetailModel.roundDrafts`: the fidelity, or the running config.
    static func key(preset: String?) -> String { preset ?? "shaping" }

    /// Differs from what it was edited from. `customized` is the Mac's to judge: an edit made and
    /// taken back is no edit.
    static func differs(_ draft: RoundDraft) -> Bool {
        var config = draft.config
        config.customized = draft.base.customized
        return config != draft.base
    }

    var dirty: Bool { Self.differs(RoundDraft(base: base, config: editor.config)) }
    /// The Mac changed these rounds since the edit began: sending it would be refused.
    var stale: Bool { base != current }
    var draft: RoundDraft { RoundDraft(base: base, config: editor.config) }

    /// nil (read-only, as before the editor existed) unless the Mac said it takes edits
    /// (`editRounds`) and sent what the menus are built from; while choosing, only for a fidelity
    /// the chooser offers, and while shaping, only with what has run (`roundsLock`).
    static func make(detail: WireIntakeDetail, preset: String?, drafts: [String: RoundDraft]) -> RoundEditing? {
        guard detail.editRounds == true, detail.steer == true, let menu = detail.roundsMenu else { return nil }
        let key = key(preset: preset)
        let current: WireRoundConfig, lock: WireRoundsLock?
        if let preset {
            guard FidelityChooser.options(detail: detail) != nil,
                  let stock = detail.choice?.presets?.first(where: { $0.preset == preset })?.config else { return nil }
            current = stock
            lock = nil
        } else {
            guard detail.summary.state == "shaping", let running = detail.roundConfig, let held = detail.roundsLock else { return nil }
            current = running
            lock = held
        }
        let draft = drafts[key]
        return RoundEditing(editor: RoundEditor(config: draft?.config ?? current, menu: menu, lock: lock),
                            key: key, current: current, base: draft?.base ?? current)
    }
}
