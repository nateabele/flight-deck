import Foundation

/// The symbols offered by the icon picker.
///
/// Curated rather than exhaustive. There is no public API to enumerate SF Symbols, so a full
/// catalog would mean bundling a ~6000-name list of which almost none describe a developer
/// tool. Each entry carries keywords because the names are not guessable: nobody searching for
/// a git client types "arrow.triangle.branch".
enum SymbolCatalog {
    struct Entry: Identifiable, Equatable {
        var name: String
        var keywords: [String]
        var id: String { name }
    }

    static let all: [Entry] = [
        Entry(name: "chevron.left.forwardslash.chevron.right", keywords: ["editor", "code", "ide"]),
        Entry(name: "terminal", keywords: ["terminal", "shell", "console"]),
        Entry(name: "arrow.triangle.branch", keywords: ["git", "branch", "vcs", "fork"]),
        Entry(name: "arrow.triangle.pull", keywords: ["git", "pull request", "merge", "vcs"]),
        Entry(name: "folder", keywords: ["files", "finder", "directory"]),
        Entry(name: "doc.text", keywords: ["document", "file", "notes"]),
        Entry(name: "hammer", keywords: ["build", "compile", "make"]),
        Entry(name: "wrench.and.screwdriver", keywords: ["tools", "settings", "utility"]),
        Entry(name: "ladybug", keywords: ["debug", "bug", "debugger"]),
        Entry(name: "gearshape", keywords: ["settings", "config", "preferences"]),
        Entry(name: "globe", keywords: ["browser", "web", "internet"]),
        Entry(name: "cloud", keywords: ["deploy", "server", "remote"]),
        Entry(name: "server.rack", keywords: ["server", "database", "infra"]),
        Entry(name: "cylinder.split.1x2", keywords: ["database", "db", "sql"]),
        Entry(name: "chart.bar", keywords: ["metrics", "analytics", "dashboard"]),
        Entry(name: "magnifyingglass", keywords: ["search", "find", "grep"]),
        Entry(name: "paintbrush", keywords: ["design", "format", "style"]),
        Entry(name: "play.rectangle", keywords: ["run", "start", "execute"]),
        Entry(name: "checkmark.seal", keywords: ["test", "verify", "lint"]),
        Entry(name: "book", keywords: ["docs", "documentation", "manual"]),
        Entry(name: "envelope", keywords: ["mail", "message", "email"]),
        Entry(name: "bubble.left.and.bubble.right", keywords: ["chat", "slack", "message"]),
        Entry(name: "calendar", keywords: ["calendar", "schedule", "meeting"]),
        Entry(name: "list.bullet.rectangle", keywords: ["issues", "tasks", "tickets", "jira"]),
        Entry(name: "square.grid.2x2", keywords: ["apps", "launcher", "grid"]),
        Entry(name: "bolt", keywords: ["fast", "action", "run"]),
        Entry(name: "star", keywords: ["favorite", "bookmark"]),
        Entry(name: "tray.full", keywords: ["inbox", "queue", "logs"]),
    ]

    /// Matches the symbol name or any keyword, case-insensitively. An empty query is "show
    /// everything" rather than "show nothing", so opening the picker shows the grid.
    static func matching(_ query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            entry.name.lowercased().contains(needle)
                || entry.keywords.contains { $0.lowercased().contains(needle) }
        }
    }
}
