import SwiftUI

/// Translucent tool buttons floating over the terminal's top-right corner.
///
/// Chrome matches `TerminalSearchBar` deliberately: the two stack in the same corner, and two
/// different treatments there would read as two unrelated pieces of UI. That shared treatment
/// now lives in `FloatingChrome` rather than being hard-coded identically in both places, so
/// it cannot drift — it is Liquid Glass where the system has it, the previous material below.
struct ToolOverlay: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var model: ToolOverlayModel

    let monitor: ToolOverlayInputMonitor
    /// No bare-default `ShellToolLauncher()` here on purpose: that default silently ignores the
    /// Shell & Environment pane, and a same-looking property with two different unconfigured
    /// defaults (here and in `AppDelegate`) is exactly how that went unnoticed before. Callers
    /// build one from `ShellToolLauncher.configured(preferences)` instead.
    var launcher: ToolLaunching

    private var visibleTools: [ToolDefinition] {
        preferences.tools.filter(\.showsInOverlay)
    }

    private var hasSelection: Bool { store.selectedSessionID != nil }

    /// Watches ⌘ so the sprocket can appear mid-chord, the same mechanism the sidebar's
    /// New Session button uses to relabel itself. Local monitor, so it costs nothing while
    /// another app is frontmost and needs no accessibility permission.
    @StateObject private var modifiers = ModifierWatcher()

    private var commandHeld: Bool { modifiers.flags.contains(.command) }

    var body: some View {
        Group {
            if visibleTools.isEmpty {
                EmptyView()
            } else {
                HStack(spacing: 6) {
                    // Revealed while ⌘ is held. Leading edge, and the tool buttons do NOT
                    // shift under the pointer when it appears: the bar is pinned to the
                    // terminal's top-RIGHT corner, so growing by one button extends it
                    // leftward and every existing icon keeps its screen position.
                    //
                    // Not `.disabled(!hasSelection)` like the tools are: a tool with no
                    // working directory cannot run, but configuring tools is exactly what you
                    // want to reach when nothing is set up yet — matching
                    // `ToolsMenuController.validateMenuItem`, which only gates `runTool`.
                    if commandHeld {
                        Button {
                            ToolsPreferencesOpener.open(preferences)
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .help("Configure Tools…")
                        .accessibilityIdentifier("tool-button-configure")
                        .transition(.opacity)
                    }
                    ForEach(visibleTools) { tool in
                        Button {
                            ToolRunner.run(tool, store: store, launcher: launcher)
                        } label: {
                            Image(systemName: tool.symbol)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!hasSelection)
                        .help(helpText(for: tool))
                        .accessibilityIdentifier("tool-button-\(tool.name)")
                    }
                }
                // Quick, because it tracks a key being held rather than a deliberate reveal.
                .animation(.easeOut(duration: 0.12), value: commandHeld)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                // Shared with `TerminalSearchBar`: Liquid Glass on macOS 26+, the previous
                // material/border/shadow below it. See `FloatingChrome`.
                .floatingChrome()
                .padding(8)
                .opacity(model.isVisible ? 1 : 0)
                // Asymmetric on purpose: appearing has to feel immediate when you reach for
                // the corner, while vanishing should not snap away under the pointer.
                .animation(
                    model.isVisible ? .easeOut(duration: 0.15) : .easeIn(duration: 0.4),
                    value: model.isVisible
                )
                // Invisible buttons must not be clickable, or the corner would swallow clicks
                // meant for the terminal underneath.
                .allowsHitTesting(model.isVisible)
                .onHover { model.hoverChanged($0) }
            }
        }
        .onAppear {
            monitor.onMouseMovedOverTerminal = { model.mouseMoved() }
            monitor.onKeyPressed = { model.keyPressed() }
            monitor.start()
            modifiers.start()
        }
        .onDisappear {
            monitor.stop()
            modifiers.stop()
        }
    }

    private func helpText(for tool: ToolDefinition) -> String {
        guard let shortcut = tool.shortcut else { return tool.name }
        return "\(tool.name) \(shortcut.displayString)"
    }
}
