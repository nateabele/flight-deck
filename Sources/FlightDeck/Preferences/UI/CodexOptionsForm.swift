import SwiftUI

/// Codex session defaults, inherited by project overrides and applied at creation and resume.
struct CodexOptionsForm: View {
    @ObservedObject var preferences: PreferencesStore
    /// Non-nil in the Projects tab: bind straight to that project's override instead of the
    /// global codex row `options` otherwise resolves through `preferences`. Mirrors how
    /// `FlagEditor` takes `flags` from its caller rather than always reading the global row.
    var projectOverride: Binding<CodexThreadOptions>?
    /// Rendered as the leading `Section` of this `Form`, mirroring `FlagEditor.header`. The
    /// Projects tab uses it for the agent and account pickers; the Agents tab passes nothing.
    var header: (() -> AnyView)?
    @State private var newDir = ""

    /// Internal rather than private so `CodexSchemaConformanceTests` can assert these against
    /// `SandboxMode` and `AskForApproval` in codex's generated schema — a picker offering a
    /// value codex does not accept is a silently broken setting, which is the class of bug
    /// this whole file's adapter layer keeps producing.
    static let sandboxes = ["read-only", "workspace-write", "danger-full-access"]
    static let approvalPolicies = ["on-request", "never"]

    /// Reads and writes the codex row's options within `preferences.agents`, wherever that
    /// row currently sits — the list's order is the shortcut binding, not a storage index, so
    /// this looks the row up by id rather than assuming a position. Skipped entirely when a
    /// `projectOverride` binding was supplied.
    private var options: Binding<CodexThreadOptions> {
        projectOverride ?? Binding(
            get: {
                guard case .codex(let opts)? = preferences.preferences.agents
                    .first(where: { $0.id == .codex })?.options
                else { return CodexThreadOptions() }
                return opts
            },
            set: { newValue in
                guard let index = preferences.preferences.agents.firstIndex(where: { $0.id == .codex })
                else { return }
                preferences.preferences.agents[index].options = .codex(newValue)
            }
        )
    }

    var body: some View {
        Form {
            if let header { header() }
            if projectOverride == nil { AgentStartupSection(preferences: preferences) }
            Section("Model & Effort") {
                TextField(
                    "Model",
                    text: Binding(
                        get: { options.wrappedValue.model ?? "" },
                        set: { options.wrappedValue.model = $0.isEmpty ? nil : $0 }
                    )
                )
                Text("Leave blank to use Codex’s configured model.")
                    .font(.caption).foregroundStyle(.secondary)
                choice("Reasoning effort", field: \.reasoningEffort,
                       values: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
                TextField("Custom reasoning effort", text: string(\.reasoningEffort))
                    .help("Supported levels depend on the selected model.")
                choice("Reasoning summary", field: \.reasoningSummary, values: ["auto", "concise", "detailed", "none"])
                choice("Response detail", field: \.verbosity, values: ["low", "medium", "high"])
            }

            Section("Permissions & Tools") {
                Picker(
                    "Sandbox",
                    selection: Binding(
                        get: { options.wrappedValue.sandbox ?? "" },
                        set: { options.wrappedValue.sandbox = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("Codex’s default").tag("")
                    ForEach(Self.sandboxes, id: \.self) { Text($0).tag($0) }
                }

                Picker(
                    "Approval",
                    selection: Binding(
                        get: { options.wrappedValue.approvalPolicy ?? "" },
                        set: { options.wrappedValue.approvalPolicy = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("Codex’s default").tag("")
                    ForEach(Self.approvalPolicies, id: \.self) { Text($0).tag($0) }
                    if let current = options.wrappedValue.approvalPolicy,
                       !Self.approvalPolicies.contains(current) {
                        Text("\(current) (saved setting)").tag(current)
                    }
                }
                choice("Web search", field: \.webSearch, values: ["disabled", "cached", "indexed", "live"])
                Picker("Sandbox network access", selection: Binding(
                    get: { options.wrappedValue.networkAccess.map { $0 ? "enabled" : "disabled" } ?? "" },
                    set: { options.wrappedValue.networkAccess = $0.isEmpty ? nil : $0 == "enabled" }
                )) {
                    Text("Codex’s default").tag("")
                    Text("Enabled").tag("enabled")
                    Text("Disabled").tag("disabled")
                }
                Text("Network access and additional writable directories apply to the workspace-write sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Context & Prompts") {
                Text("Additional instructions")
                TextEditor(text: string(\.developerInstructions))
                    .frame(minHeight: 80)
                    .help("Additional developer instructions for the session.")
                TextField("Model instructions file", text: string(\.modelInstructionsFile))
                    .help("Path to a file replacing Codex’s built-in model instructions.")
            }

            Section("Additional directories") {
                ForEach(options.wrappedValue.addDirs, id: \.self) { dir in
                    HStack(spacing: 6) {
                        Text(dir)
                        Spacer()
                        Button {
                            options.wrappedValue.addDirs.removeAll { $0 == dir }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 6) {
                    TextField("/path/to/dir", text: $newDir)
                    Button("Add") {
                        let dir = newDir.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !dir.isEmpty, !options.wrappedValue.addDirs.contains(dir) else { return }
                        options.wrappedValue.addDirs.append(dir)
                        newDir = ""
                    }
                    .disabled(newDir.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func string(_ field: WritableKeyPath<CodexThreadOptions, String?>) -> Binding<String> {
        Binding(get: { options.wrappedValue[keyPath: field] ?? "" },
                set: { options.wrappedValue[keyPath: field] = $0.isEmpty ? nil : $0 })
    }

    private func choice(_ label: String, field: WritableKeyPath<CodexThreadOptions, String?>,
                        values: [String]) -> some View {
        Picker(label, selection: string(field)) {
            Text("Codex’s default").tag("")
            ForEach(values, id: \.self) { Text($0).tag($0) }
            // Keep a model-advertised value visible when it is newer than our suggestions.
            if let current = options.wrappedValue[keyPath: field], !values.contains(current) {
                Text(current).tag(current)
            }
        }
    }

}
