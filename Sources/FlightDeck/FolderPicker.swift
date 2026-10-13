import AppKit

/// Modal folder chooser used to define a repo when creating a session.
enum FolderPicker {
    static func choose(prompt: String = "Open") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
