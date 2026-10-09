import IntakeKit
import SwiftUI

/// grok's and gemini's pane in Settings → Agents and, with `inherited`, in Settings → Projects:
/// the model a tab launches with, plus the knobs that CLI's TUI takes (grok's `--effort`, agy's
/// `--mode`). The same `GrokOptions`/`GeminiOptions` routing overrides write
/// (`GrokLaunchOverrides`, `GeminiLaunchOverrides`), so a hand-picked model and a routed one are
/// one setting resolved one way (`PreferencesStore.resolvedOptions`).
///
/// Rows are `FlagRow`s, so the menus sit in the same trailing input column as claude's flags and
/// the project account pickers, and a project row shows "Inherited: …" and a revert button
/// exactly as claude's do.
struct TabModelOptionsForm: View {
    let agent: AgentID
    @Binding var options: AgentOptions
    /// The global row's options, in the Projects tab only: what an unset field here inherits.
    var inherited: AgentOptions?
    /// Planning's detection (`IntakeService.detectedModels`); nil until it lands.
    var available: AvailableModels?
    /// Leading sections, as `CodexOptionsForm.header` — the Projects tab's agent and accounts.
    var header: (() -> AnyView)?

    var body: some View {
        let choices = TabModelChoices(agent: agent, available: available,
                                      chosenModel: options.tabModel ?? inherited?.tabModel)
        Form {
            if let header { header() }
            Section {
                FlagRow(spec: Self.spec("Model", .choice(choices.models, allowsCustom: true),
                                        help: "The model a new or resumed \(agent.displayName) tab starts on."),
                        value: field(\.tabModel), inherited: inherited?.tabModel.map(FlagValue.value),
                        defaultTitle: choices.defaultModelTitle, choiceWidth: 260)
                if !choices.efforts.isEmpty {
                    FlagRow(spec: Self.spec("Effort", .choice(choices.efforts, allowsCustom: false),
                                            help: "grok's --effort: how long the model thinks per turn."),
                            value: field(\.tabEffort), inherited: inherited?.tabEffort.map(FlagValue.value),
                            defaultTitle: "\(agent.rawValue)'s default")
                }
                if !choices.modes.isEmpty {
                    FlagRow(spec: Self.spec("Mode", .choice(choices.modes, allowsCustom: false),
                                            help: "agy's --mode. Shift+Tab in the tab still cycles it."),
                            value: field(\.tabMode), inherited: inherited?.tabMode.map(FlagValue.value),
                            defaultTitle: "Default (request review)")
                }
            } header: {
                Text("Model")
            } footer: {
                if !choices.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(choices.notes, id: \.self) { Text($0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tab-model-notes-\(agent.rawValue)")
                }
            }

            Section("Launch command") {
                Text(Self.launchPreview(resolved))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("tab-model-launch-\(agent.rawValue)")
            }
        }
        .formStyle(.grouped)
    }

    /// What a launch here resolves to: this pane's fields over the global row's, by the same
    /// merge `PreferencesStore.resolvedOptions` applies.
    private var resolved: AgentOptions {
        switch (inherited, options) {
        case (.grok(let g)?, .grok(let p)): .grok(GrokOptions.merge(global: g, project: p))
        case (.gemini(let g)?, .gemini(let p)): .gemini(GeminiOptions.merge(global: g, project: p))
        default: options
        }
    }

    /// The command a new tab types, built by the adapters' own spelling of it — so the preview
    /// cannot show a flag the tab would not get (agy's non-Gemini model falls back here too).
    static func launchPreview(_ options: AgentOptions) -> String {
        switch options {
        case .grok(let grok): "grok -s ⟨generated⟩" + GrokAdapter.flagTail(grok)
        case .gemini(let gemini): "agy --model \(GeminiAdapter.model(for: gemini))" + GeminiAdapter.modeFlag(gemini)
        case .claude, .codex: ""
        }
    }

    private static func spec(_ label: String, _ kind: FlagSpec.Kind, help: String) -> FlagSpec {
        FlagSpec("--\(label.lowercased())", kind: kind, section: .modelEffort, label: label, help: help)
    }

    /// One field of `options` as `FlagRow`'s value. `.value("")` (a "Custom…" pick before any
    /// text) is kept as "", not nil, or the custom text field would vanish the moment it opens.
    private func field(_ path: WritableKeyPath<AgentOptions, String?>) -> Binding<FlagValue?> {
        Binding(
            get: { options[keyPath: path].map(FlagValue.value) },
            set: { newValue in
                switch newValue {
                case .value(let raw)?: options[keyPath: path] = raw
                default: options[keyPath: path] = nil
                }
            }
        )
    }
}

/// Hands planning's model detection to a pane, re-rendering it when the off-main probe lands.
/// Takes the service rather than a value because the probe starts at launch and Settings may
/// open before it finishes.
struct DetectedModelsReader<Content: View>: View {
    @ObservedObject var service: IntakeService
    @ViewBuilder let content: (AvailableModels?) -> Content

    var body: some View { content(service.detectedModels) }
}
