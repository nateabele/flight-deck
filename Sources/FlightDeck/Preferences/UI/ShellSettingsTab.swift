import AppKit
import SwiftUI

/// The shell and environment new sessions are spawned into.
struct ShellSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @State private var newKey = ""
    @State private var newValue = ""

    private var shell: Binding<ShellPreferences> { $preferences.preferences.shell }

    var body: some View {
        Form {
            Section("Shell") {
                LabeledContent("Shell") {
                    HStack(spacing: 6) {
                        TextField(
                            ShellResolver.resolve(),
                            text: Binding(
                                get: { shell.wrappedValue.shellOverride ?? "" },
                                set: { shell.wrappedValue.shellOverride = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .frame(width: 240)
                        Button("Choose…") { chooseShell() }
                    }
                }
                Text("Empty uses $SHELL, falling back to /bin/zsh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment") {
                Toggle(
                    "Clear CLAUDE_CODE_CHILD_SESSION in new sessions",
                    isOn: shell.clearChildSessionMarker
                )
                Text("Claude Code sets this marker for nested sessions, and it turns transcript saving off — which silently stops the sidebar from picking up renames. Leave on unless you know you need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(shell.wrappedValue.environment.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        HStack(spacing: 6) {
                            TextField(
                                "",
                                text: Binding(
                                    get: { shell.wrappedValue.environment[key] ?? "" },
                                    set: { shell.wrappedValue.environment[key] = $0 }
                                )
                            )
                            .frame(width: 200)
                            Button {
                                shell.wrappedValue.environment.removeValue(forKey: key)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                LabeledContent("Add") {
                    HStack(spacing: 6) {
                        TextField("NAME", text: $newKey).frame(width: 120)
                        TextField("value", text: $newValue).frame(width: 160)
                        Button("Add") {
                            let key = newKey.trimmingCharacters(in: .whitespaces)
                            guard !key.isEmpty else { return }
                            shell.wrappedValue.environment[key] = newValue
                            newKey = ""
                            newValue = ""
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section {
                Text("Applies to new sessions. Running sessions keep the environment they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseShell() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/bin")
        if panel.runModal() == .OK, let url = panel.url {
            shell.wrappedValue.shellOverride = url.path
        }
    }
}
