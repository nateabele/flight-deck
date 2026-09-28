import AppKit

extension ShortcutCatalog.MenuNode {
    init(_ item: NSMenuItem) {
        self.init(
            title: item.title,
            keyEquivalent: item.keyEquivalent,
            // Only the four chord modifiers: `keyEquivalentModifierMask` can carry device bits
            // that would otherwise render as nothing and break equality in `chord`.
            modifiers: item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]),
            isHidden: item.isHidden || item.isSeparatorItem,
            children: item.submenu?.items.map(Self.init) ?? []
        )
    }
}

extension ShortcutCatalog {
    /// Read fresh on every open, never cached: menus rebuild as agents and accounts change.
    @MainActor static func currentGroups() -> [ShortcutGroup] {
        groups(from: NSApp.mainMenu?.items.map(MenuNode.init) ?? [])
    }
}
