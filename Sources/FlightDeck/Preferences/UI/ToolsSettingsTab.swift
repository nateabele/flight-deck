import SwiftUI

/// External tools, their icons, and their shortcuts.
struct ToolsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore

    @State private var selection: UUID?

    private var tools: [ToolDefinition] { preferences.tools }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                toolList
                Divider()
                detail
            }
            Divider()
            variableReference
        }
    }

    private var toolList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                // The list ORDER is semantic, like the Agents tab's: it is the overlay's
                // left-to-right order, which is why this is reorderable.
                ForEach(tools) { tool in
                    HStack(spacing: 6) {
                        Image(systemName: tool.symbol).frame(width: 18)
                        Text(tool.name)
                        Spacer()
                        if let shortcut = tool.shortcut {
                            Text(shortcut.displayString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(tool.id)
                }
                .onMove { source, destination in
                    var list = tools
                    list.move(fromOffsets: source, toOffset: destination)
                    preferences.tools = list
                }
            }
            .accessibilityIdentifier("tools-list")

            HStack(spacing: 4) {
                Button {
                    let tool = ToolDefinition(name: "New Tool", symbol: "wrench.and.screwdriver", command: "")
                    preferences.tools.append(tool)
                    selection = tool.id
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("tools-add")

                Button {
                    guard let selection else { return }
                    preferences.tools.removeAll { $0.id == selection }
                    self.selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .accessibilityIdentifier("tools-remove")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let index = tools.firstIndex(where: { $0.id == selection }) {
            Form {
                LabeledContent("Name") {
                    TextField("", text: binding(index, \.name)).frame(width: 200)
                }
                LabeledContent("Icon") {
                    SymbolPicker(symbol: binding(index, \.symbol))
                }
                LabeledContent("Command") {
                    TextField("", text: binding(index, \.command))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 260)
                }
                LabeledContent("Runs") {
                    // The preview is what makes shell quoting visible up front, rather than
                    // something discovered the first time a path has a space in it. Free —
                    // expansion is already a pure function.
                    Text(preview(for: tools[index]))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: 260, alignment: .leading)
                }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: binding(index, \.shortcut), toolName: tools[index].name)
                }
                Toggle("Show in terminal overlay", isOn: binding(index, \.showsInOverlay))
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            // Forces a remount, not just an update, when the selected tool changes. That resets
            // the recorder's @State (so an armed monitor tears down via onDisappear) and drops
            // the closures captured by every `binding(index, _)` below, which otherwise keep
            // referring to the tool the user navigated away from.
            .id(tools[index].id)
        } else {
            ContentUnavailableView("No Tool Selected", systemImage: "wrench.and.screwdriver")
                .frame(maxWidth: .infinity)
        }
    }

    private var variableReference: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Available variables")
                .font(.caption.bold())
            Text("${cwd} · ${project} · ${root} · ${projectName} · ${session} · ${agent} · ${conversationID} · ${transcript} · ${home}")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Values are quoted, so paths with spaces stay one argument. Anything else — $EDITOR, ${HOME} — is left for your login shell, which runs the command with your profile loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    /// Expanded against the real selection when there is one, so the preview shows the paths
    /// the user will actually get. The sample keeps the row from being blank otherwise.
    private func preview(for tool: ToolDefinition) -> String {
        let context = sessions.toolContext() ?? ToolContext(
            workingDirectory: "/Users/you/Projects/example",
            projectPath: "/Users/you/Projects/example",
            projectName: "example",
            sessionTitle: "session",
            agent: .claude,
            conversationID: UUID(),
            transcriptPath: nil
        )
        return ToolTemplate.expand(tool.command, in: context)
    }

    private func binding<V>(
        _ index: Int, _ keyPath: WritableKeyPath<ToolDefinition, V>
    ) -> Binding<V> {
        Binding(
            get: { preferences.tools[index][keyPath: keyPath] },
            set: { newValue in
                // The `.id()` remount above is the primary defence against a stale index, but
                // it depends on SwiftUI's identity semantics; this is the cheap backstop against
                // an out-of-range write crashing the whole preferences window.
                guard preferences.tools.indices.contains(index) else { return }
                preferences.tools[index][keyPath: keyPath] = newValue
            }
        )
    }
}
