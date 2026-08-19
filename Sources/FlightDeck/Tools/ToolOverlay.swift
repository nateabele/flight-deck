import SwiftUI

/// Translucent tool buttons floating over the terminal's top-right corner.
///
/// Chrome matches `TerminalSearchBar` deliberately: the two stack in the same corner, and two
/// different treatments there would read as two unrelated pieces of UI.
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

    var body: some View {
        Group {
            if visibleTools.isEmpty {
                EmptyView()
            } else {
                HStack(spacing: 6) {
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .shadow(radius: 4, y: 2)
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
        }
        .onDisappear { monitor.stop() }
    }

    private func helpText(for tool: ToolDefinition) -> String {
        guard let shortcut = tool.shortcut else { return tool.name }
        return "\(tool.name) \(shortcut.displayString)"
    }
}
