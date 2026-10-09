import IntakeKit
import SwiftUI

/// OpenCode's pane in the Agents tab, and — via `projectOverride` — in the Projects tab.
///
/// Two typed fields, like codex's pane and for the same reason: they travel in the
/// `POST /session` body that creates the conversation, not on a command line. Providers
/// themselves (an Ollama endpoint, an API key) are OpenCode's own configuration in
/// `opencode.json`; this pane only chooses among what that file already defines.
struct OpenCodeOptionsForm: View {
    @ObservedObject var preferences: PreferencesStore
    /// Non-nil in the Projects tab — see `CodexOptionsForm.projectOverride`.
    var projectOverride: Binding<OpenCodeOptions>?
    var header: (() -> AnyView)?

    /// OpenCode's two built-in agents. A user-defined agent from `opencode.json` is typed in.
    static let builtInAgents = ["build", "plan"]

    private var options: Binding<OpenCodeOptions> {
        projectOverride ?? Binding(
            get: {
                guard case .opencode(let opts)? = preferences.preferences.agents
                    .first(where: { $0.id == .opencode })?.options
                else { return OpenCodeOptions() }
                return opts
            },
            set: { newValue in
                guard let index = preferences.preferences.agents.firstIndex(where: { $0.id == .opencode })
                else { return }
                preferences.preferences.agents[index].options = .opencode(newValue)
            }
        )
    }

    var body: some View {
        Form {
            if let header { header() }
            Section {
                TextField(
                    "opencode.json's default",
                    text: Binding(
                        get: { options.wrappedValue.model ?? "" },
                        set: { options.wrappedValue.model = $0.isEmpty ? nil : $0 }
                    )
                )
                .accessibilityIdentifier("opencode-model-field")
            } header: {
                Text("Model")
            } footer: {
                // Says why a value is ignored rather than ignoring it silently: a model with no
                // provider prefix is dropped at creation (`OpenCodeOptions.modelReference`).
                if let model = options.wrappedValue.model, options.wrappedValue.modelReference == nil {
                    Text("“\(model)” names no provider and will be ignored. Use provider/model, e.g. ollama/qwen3-coder:32k.")
                        .foregroundStyle(.red)
                } else {
                    Text("provider/model, as `opencode models` lists it — e.g. ollama/qwen3-coder:32k.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Agent") {
                Picker(
                    "Agent",
                    selection: Binding(
                        get: { Self.builtInAgents.contains(options.wrappedValue.agent ?? "") ? options.wrappedValue.agent ?? "" : (options.wrappedValue.agent == nil ? "" : "custom") },
                        set: { choice in
                            switch choice {
                            case "": options.wrappedValue.agent = nil
                            case "custom": if options.wrappedValue.agent == nil { options.wrappedValue.agent = "" }
                            default: options.wrappedValue.agent = choice
                            }
                        }
                    )
                ) {
                    Text("OpenCode's default").tag("")
                    ForEach(Self.builtInAgents, id: \.self) { Text($0).tag($0) }
                    Text("Other…").tag("custom")
                }
                if let agent = options.wrappedValue.agent, !Self.builtInAgents.contains(agent) {
                    TextField(
                        "agent name from opencode.json",
                        text: Binding(
                            get: { agent },
                            set: { options.wrappedValue.agent = $0.isEmpty ? nil : $0 }
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}
