import AppKit
import SwiftUI

/// Records a chord for a tool.
///
/// Arms a local `keyDown` monitor and **consumes** the next key event, which is what lets even
/// ⌘Q be recorded: local monitors run ahead of `NSApplication.sendEvent`, and therefore ahead
/// of `performKeyEquivalent`, so nothing else sees the key first.
struct ShortcutRecorder: View {
    @Binding var shortcut: ToolShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

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
        guard let existing = Self.findConflict(shortcut, in: mainMenu) else { return nil }
        return "\(shortcut.displayString) is already \(existing)"
    }

    private static func findConflict(_ shortcut: ToolShortcut, in menu: NSMenu) -> String? {
        for item in menu.items {
            if let submenu = item.submenu, submenu.title != "Tools",
               let found = findConflict(shortcut, in: submenu) {
                return found
            }
            guard item.submenu == nil else { continue }
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
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels, so a recorder can be dismissed without binding something.
        if event.keyCode == 53 { stop(); return }
        // Delete clears.
        if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; stop(); return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // At least ⌘ or ⌃ is required. A bare letter or a ⇧/⌥ combination would be a valid
        // menu key equivalent that swallows ordinary typing everywhere in the app.
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }

        shortcut = ToolShortcut(key: characters, modifiers: modifiers)
        stop()
    }
}
