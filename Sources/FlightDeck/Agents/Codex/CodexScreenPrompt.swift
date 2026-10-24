import FleetKit
import Foundation

/// Local TUI menus (including directory/hook trust) have no native server request.
/// The full numbered menu supplies both identity and the choices the phone can answer.
enum CodexScreenPrompt {
    static func read(_ viewport: String) -> OpenPrompt? {
        guard viewport.contains("Press enter") || viewport.contains("Enter to select"),
              let menu = ChoiceDialog.menu(inViewport: viewport, marker: ChoiceDialog.codexMarker) else { return nil }
        let lines = viewport.components(separatedBy: "\n")
        let marker = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("› ") }
        let firstRow = marker.flatMap { end in
            lines[...end].lastIndex {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("1. ") || line.hasPrefix("› 1. ")
            }
        }
        // The last line above the options can be a heredoc terminator. Carry the whole
        // approval block, including the reason, environment and multi-line command.
        // Its contents also distinguish commands offering identical Yes/No choices.
        let approvalStart = firstRow.flatMap { row in
            lines[..<row].lastIndex {
                $0.trimmingCharacters(in: .whitespaces) == "Would you like to run the following command?"
            }
        }
        let prompt: String
        if let start = approvalStart, let end = firstRow {
            prompt = lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prompt = menu.prompt ?? "Codex is waiting for you to choose"
        }
        return .question(callID: ScreenPromptID.menu(prompt: "codex:" + prompt, labels: menu.rows.map(\.label)),
            [.init(header: approvalStart == nil ? nil : "Command approval", question: prompt,
                   options: menu.rows.map { .init(label: $0.label, detail: $0.detail) }, allowsOther: false)])
    }
}
