import Foundation

/// One external tool: a shell command template, an icon, and an optional chord.
///
/// The array's ORDER is semantic, like `AgentSettings`': it is the overlay's left-to-right
/// order, which is why the preferences list is drag-reorderable.
struct ToolDefinition: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    /// An SF Symbol name. Symbols rather than app icons because they are monochrome templates
    /// that tint cleanly against `.regularMaterial` at any opacity, and cost one string rather
    /// than a stored bundle path that can go stale.
    var symbol: String
    /// A `ToolTemplate` template, e.g. `$EDITOR ${cwd}`.
    var command: String
    /// nil means the tool is still reachable from the menu and the overlay, just unbound.
    var shortcut: ToolShortcut?
    var showsInOverlay: Bool

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        command: String,
        shortcut: ToolShortcut? = nil,
        showsInOverlay: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.command = command
        self.shortcut = shortcut
        self.showsInOverlay = showsInOverlay
    }
}
