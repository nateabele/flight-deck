import Foundation
import IntakeKit

/// Which options pane an agent's row edits, in Settings → Agents and per project. A value rather
/// than a `switch` inside each view, so a new agent cannot silently fall through to another
/// agent's pane — grok and gemini once did, and edited claude's global flags under their own name.
enum AgentOptionsPane: Equatable {
    /// claude's flag catalog (`FlagEditor`).
    case claudeFlags
    /// codex's typed `thread/start` params (`CodexOptionsForm`).
    case codex
    /// A model picker over the CLI's own list, plus whatever knobs its TUI takes
    /// (`TabModelOptionsForm`).
    case model(AgentID)
    /// OpenCode's model and OpenCode agent (`OpenCodeOptionsForm`). Not `.model`: its model is
    /// `provider/model` across whatever providers the person configured, and the pane also
    /// chooses which OpenCode agent (`build`, `plan`, their own) drives the session.
    case opencode

    init(agent: AgentID) {
        switch agent {
        case .claude: self = .claudeFlags
        case .codex: self = .codex
        case .grok, .gemini: self = .model(agent)
        case .opencode: self = .opencode
        }
    }
}

/// What a grok or gemini tab's model pane offers, worked out from planning's detection
/// (`IntakeService.availableModels()`, the `grok models` / `agy models` run at launch) — never a
/// second probe of its own. Pure, so the choices and every note are unit-tested; the view only
/// lays them out.
struct TabModelChoices: Equatable {
    let agent: AgentID
    /// The model menu: the CLI's own list when detection read one, else the profile's fallback
    /// (`RoundConfigEditor.modelSuggestions`, the list the Rounds editor offers too).
    let models: [String]
    /// The effort menu; empty when the CLI has no separate knob (agy's ids carry their effort).
    let efforts: [String]
    /// agy's `--mode` values; empty for an agent with no mode flag a tab can use.
    let modes: [String]
    /// The model menu's "nothing chosen" row, naming what a tab would then actually run.
    let defaultModelTitle: String
    /// Why something is missing or will not apply, in planning's words where planning has them.
    let notes: [String]

    /// `available` nil means detection has not landed yet (it runs off the main actor at launch).
    init(agent: AgentID, available: AvailableModels?, chosenModel: String?) {
        self.agent = agent
        let profile = AgentProfiles.profile(for: agent)
        let listed = available?.models[agent].flatMap { $0.isEmpty ? nil : $0 }
        models = RoundConfigEditor.modelSuggestions(for: agent, detected: listed ?? [])
        efforts = profile.modelCatalog.effortValues
        modes = agent == .gemini ? GeminiOptions.modes : []

        // gemini always names its model at launch (`GeminiProfile.defaultPlanningModel`), so its
        // default is a known id; grok's is whatever the account defaults to, which only its own
        // list (default first, `GrokProfile.parseModelList`) can say.
        if agent == .gemini {
            defaultModelTitle = "Default (\(GeminiProfile.defaultPlanningModel))"
        } else if let first = listed?.first {
            defaultModelTitle = "Default (\(first))"
        } else {
            defaultModelTitle = "\(agent.rawValue)'s default"
        }

        var notes: [String] = []
        let binary = profile.binaryName
        if let reason = available?.unavailable[agent] {
            notes.append("Unavailable: \(reason)")
        } else if available == nil {
            notes.append("Still asking \(binary) for this account's models; showing the built-in list.")
        } else if listed == nil {
            notes.append("`\(binary) models` listed nothing; showing the built-in list.")
        }
        if let chosen = chosenModel, !chosen.isEmpty {
            if agent == .gemini, !GeminiAdapter.isLaunchableModel(chosen) {
                // `GeminiAdapter.model(for:)` falls back without a word, so say it here.
                notes.append("A gemini tab runs Gemini models only; this one starts on \(GeminiProfile.defaultPlanningModel) instead.")
            } else if let listed, !listed.contains(chosen) {
                notes.append("`\(binary) models` does not list \(chosen) for this account.")
            }
        }
        self.notes = notes
    }
}

/// The grok and gemini fields `TabModelOptionsForm` edits, addressable by key path. Reading
/// another agent's arm answers nil and writing one is a no-op: the pane only ever holds its own
/// agent's arm (`AgentOptionsPane`), so neither can happen from Settings.
extension AgentOptions {
    var tabModel: String? {
        get {
            switch self {
            case .grok(let o): o.model
            case .gemini(let o): o.model
            case .claude, .codex: nil
            }
        }
        set {
            switch self {
            case .grok(var o): o.model = newValue; self = .grok(o)
            case .gemini(var o): o.model = newValue; self = .gemini(o)
            case .claude, .codex: break
            }
        }
    }

    var tabEffort: String? {
        get { if case .grok(let o) = self { return o.effort }; return nil }
        set { if case .grok(var o) = self { o.effort = newValue; self = .grok(o) } }
    }

    var tabMode: String? {
        get { if case .gemini(let o) = self { return o.mode }; return nil }
        set { if case .gemini(var o) = self { o.mode = newValue; self = .gemini(o) } }
    }
}
