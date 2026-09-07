import AppKit
import SwiftUI

/// The shell and environment new sessions are spawned into.
struct ShellSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @State private var newKey = ""
    @State private var newValue = ""

    private var shell: Binding<ShellPreferences> { $preferences.preferences.shell }

    private var trimmedKey: String { newKey.trimmingCharacters(in: .whitespaces) }

    /// Matches shell variable-name rules so `environmentVariables` never receives a
    /// malformed entry — whitespace or `=` in the name would corrupt the surface's
    /// environment rather than merely fail to launch.
    private var keyIsValid: Bool {
        trimmedKey.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    private var keyCollides: Bool {
        keyIsValid && shell.wrappedValue.environment[trimmedKey] != nil
    }

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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            TextField("NAME", text: $newKey).frame(width: 120)
                            TextField("value", text: $newValue).frame(width: 160)
                            Button(keyCollides ? "Replace" : "Add") {
                                guard keyIsValid else { return }
                                shell.wrappedValue.environment[trimmedKey] = newValue
                                newKey = ""
                                newValue = ""
                            }
                            .disabled(!keyIsValid)
                        }
                        if !trimmedKey.isEmpty && !keyIsValid {
                            Text("Must start with a letter or underscore, then letters, digits, or underscores.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if keyCollides {
                            Text("\"\(trimmedKey)\" already exists — this replaces its value.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Scrollback") {
                Picker(
                    "Terminal scrollback kept for reattach",
                    selection: Binding(
                        get: { preferences.scrollbackBudgetBytes },
                        set: { preferences.scrollbackBudgetBytes = $0 }
                    )
                ) {
                    ForEach(Self.scrollbackBudgetChoices, id: \.self) { bytes in
                        Text(Self.scrollbackBudgetLabel(forBytes: bytes)).tag(bytes)
                    }
                }
                .accessibilityIdentifier("prefs-scrollback-budget")
                Text("How much output a session's terminal keeps so a reattach can redraw it. Applies to a session's next cold start — a session that is already running, or merely detached, keeps the ring it started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sleep") {
                Toggle(
                    "Sleep idle sessions",
                    isOn: Binding(
                        get: { preferences.idleSleepEnabled },
                        set: { preferences.idleSleepEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("prefs-idle-sleep-enabled")

                if preferences.idleSleepEnabled {
                    Stepper(
                        "After \(preferences.sleepIdleThresholdSeconds / 60) min",
                        value: Binding(
                            get: { preferences.sleepIdleThresholdSeconds / 60 },
                            set: { preferences.sleepIdleThresholdSeconds = $0 * 60 }
                        ),
                        in: 1...120
                    )
                    .accessibilityIdentifier("prefs-idle-sleep-threshold")
                }
                // A threshold changed here applies on the next launch — see the comment on
                // `SessionStore.sleepController`'s `policy:` argument. The Off switch above
                // is live.
                Text("An idle session's agent is paused and its terminal detached, freezing the tab until you select it again — regardless of which agent it's running. A threshold change takes effect the next time Flight Deck launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Applies to new sessions. Running sessions keep the environment they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Bytes, not MiB, so the `Picker`'s `selection` binds straight to
    /// `PreferencesStore.scrollbackBudgetBytes` with no unit conversion at the call site.
    private static let scrollbackBudgetChoices: [Int] = [
        262_144, 524_288, 1_048_576, 2_097_152, 4_194_304, 8_388_608, 16_777_216,
    ]

    private static func scrollbackBudgetLabel(forBytes bytes: Int) -> String {
        bytes < 1024 * 1024 ? "\(bytes / 1024) KiB" : "\(bytes / (1024 * 1024)) MiB"
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
