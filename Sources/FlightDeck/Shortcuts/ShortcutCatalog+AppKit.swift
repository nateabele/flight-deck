import AppKit

extension ShortcutCatalog.MenuNode {
    init(_ item: NSMenuItem) {
        self.init(title: item.title, item)
    }

    /// The menu bar's own top level only (File, Edit, the application menu). AppKit draws that
    /// row from `NSMenuItem.submenu.title`, not the item's own `title`, which is routinely
    /// empty there — the application menu in particular has no title of its own at all, so
    /// without this the overlay's first group would render with a blank header. Every nested
    /// item's own title IS what gets drawn, so only the top level needs the fallback.
    init(topLevel item: NSMenuItem) {
        let submenuTitle = item.submenu?.title ?? ""
        self.init(title: submenuTitle.isEmpty ? item.title : submenuTitle, item)
    }

    private init(title: String, _ item: NSMenuItem) {
        self.init(
            title: title,
            keyEquivalent: item.keyEquivalent,
            // Only the four chord modifiers: `keyEquivalentModifierMask` can carry device bits
            // that would otherwise render as nothing and break equality in `chord`.
            modifiers: item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]),
            isHidden: item.isHidden || item.isSeparatorItem,
            // `Self.init(_:)` explicitly: a bare `Self.init` is ambiguous now that
            // `init(topLevel:)` exists too — argument labels aren't part of a function
            // value's type, so the two initializers are indistinguishable without one.
            // Children are never top-level nodes regardless of which init built this one.
            children: item.submenu?.items.map(Self.init(_:)) ?? []
        )
    }
}

extension ShortcutCatalog {
    /// Read fresh on every open, never cached: menus rebuild as agents and accounts change.
    @MainActor static func currentGroups() -> [ShortcutGroup] {
        groups(from: NSApp.mainMenu?.items.map(MenuNode.init(topLevel:)) ?? [])
    }
}
