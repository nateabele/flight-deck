import AppKit
import SwiftUI

/// Records a chord for a tool.
///
/// Arms a local `keyDown` monitor and **consumes** the next key event, which is what lets even
/// ⌘Q be recorded: local monitors run ahead of `NSApplication.sendEvent`, and therefore ahead
/// of `performKeyEquivalent`, so nothing else sees the key first.
struct ShortcutRecorder: View {
    @Binding var shortcut: ToolShortcut?
    /// The name of the tool being edited, so conflict detection can skip that tool's own menu
    /// item rather than the whole Tools submenu — see `findConflict`.
    let toolName: String

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var mouseMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(buttonTitle) {
                isRecording ? stop() : start()
            }
            .frame(minWidth: 110)
            .accessibilityIdentifier("tool-shortcut-recorder")

            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this shortcut")
            }

            if let conflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private var buttonTitle: String {
        if isRecording { return "Press keys…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    /// Non-blocking: a user may genuinely want to shadow an existing command, so this warns
    /// rather than refuses. Silence would be worse — a chord the menu already owns simply
    /// never reaches the tool, with nothing on screen to explain why.
    private var conflict: String? {
        guard let shortcut, let mainMenu = NSApp.mainMenu else { return nil }
        guard let existing = Self.findConflict(shortcut, excluding: toolName, in: mainMenu) else { return nil }
        return "\(shortcut.displayString) is already \(existing)"
    }

    /// Excludes only the menu item for the tool being edited, not the whole Tools submenu.
    /// Skipping the whole submenu would hide the most likely conflict a user actually creates
    /// — giving two tools the same chord — since only one of them could ever fire.
    private static func findConflict(_ shortcut: ToolShortcut, excluding toolName: String, in menu: NSMenu) -> String? {
        for item in menu.items {
            if let submenu = item.submenu,
               let found = findConflict(shortcut, excluding: toolName, in: submenu) {
                return found
            }
            guard item.submenu == nil else { continue }
            if item.title == toolName { continue }
            if item.keyEquivalent == shortcut.key,
               item.keyEquivalentModifierMask == shortcut.modifierFlags {
                return item.title
            }
        }
        return nil
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // consumed, so the chord being recorded cannot also fire
        }
        // Defence in depth: the primary teardown is the detail form's `.id()` remount when the
        // tool selection changes (see ToolsSettingsTab), which relies on SwiftUI treating that
        // as identity change rather than an update. If that identity assumption is ever wrong,
        // an armed key monitor left running would consume every keystroke app-wide — so a click
        // anywhere, not just a key, also disarms. The event is returned unchanged so the click
        // that cancelled recording still lands on whatever it hit.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            stop()
            return event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels, so a recorder can be dismissed without binding something.
        if event.keyCode == 53 { stop(); return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Bare Delete/Backspace clears. Modified (e.g. ⌘⌫) is a bindable chord like any other —
        // otherwise nothing lets a tool bind a Delete-based shortcut at all.
        if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
            shortcut = nil
            stop()
            return
        }

        // At least ⌘ or ⌃ is required. A bare letter or a ⇧/⌥ combination would be a valid
        // menu key equivalent that swallows ordinary typing everywhere in the app.
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }

        shortcut = ToolShortcut(key: characters, modifiers: modifiers)
        stop()
    }
}
