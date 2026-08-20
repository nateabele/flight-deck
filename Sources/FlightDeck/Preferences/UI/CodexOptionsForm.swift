import SwiftUI

/// Codex's pane in the Agents tab, and — via `projectOverride` — in the Projects tab too. No
/// flag catalog, parser, serializer or shell quoting — unlike claude, codex takes these as
/// typed `thread/start` params over JSON-RPC, so there is no command line to build at all. A
/// plain `Form` binding `CodexThreadOptions`'s fields is the whole of it.
struct CodexOptionsForm: View {
    @ObservedObject var preferences: PreferencesStore
    /// Non-nil in the Projects tab: bind straight to that project's override instead of the
    /// global codex row `options` otherwise resolves through `preferences`. Mirrors how
    /// `FlagEditor` takes `flags` from its caller rather than always reading the global row.
    var projectOverride: Binding<CodexThreadOptions>?
    /// Rendered as the leading `Section` of this `Form`, mirroring `FlagEditor.header`. The
    /// Agents tab uses it for the accounts list; the Projects tab passes nothing.
    var header: (() -> AnyView)?
    @State private var newDir = ""

    /// Internal rather than private so `CodexSchemaConformanceTests` can assert these against
    /// `SandboxMode` and `AskForApproval` in codex's generated schema — a picker offering a
    /// value codex does not accept is a silently broken setting, which is the class of bug
    /// this whole file's adapter layer keeps producing.
    static let sandboxes = ["read-only", "workspace-write", "danger-full-access"]
    static let approvalPolicies = ["untrusted", "on-request", "never"]

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
            Section("Model") {
                TextField(
                    "codex's default",
                    text: Binding(
                        get: { options.wrappedValue.model ?? "" },
                        set: { options.wrappedValue.model = $0.isEmpty ? nil : $0 }
                    )
                )
            }

            Section("Sandbox") {
                Picker(
                    "Sandbox",
                    selection: Binding(
                        get: { options.wrappedValue.sandbox ?? "" },
                        set: { options.wrappedValue.sandbox = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("codex's default").tag("")
                    ForEach(Self.sandboxes, id: \.self) { Text($0).tag($0) }
                }

                Picker(
                    "Approval",
                    selection: Binding(
                        get: { options.wrappedValue.approvalPolicy ?? "" },
                        set: { options.wrappedValue.approvalPolicy = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("codex's default").tag("")
                    ForEach(Self.approvalPolicies, id: \.self) { Text($0).tag($0) }
                }
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
                        guard !newDir.isEmpty else { return }
                        options.wrappedValue.addDirs.append(newDir)
                        newDir = ""
                    }
                    .disabled(newDir.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}
