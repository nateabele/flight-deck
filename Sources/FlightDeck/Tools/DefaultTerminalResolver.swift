import AppKit

/// Picks a terminal emulator for the default Terminal tool.
///
/// macOS exposes no "default terminal" setting to read, so this probes for installed apps in
/// preference order. The result is baked into a **literal, editable command string** at
/// materialisation rather than resolved at launch: the user sees
/// `open -b com.googlecode.iterm2 ${cwd}` in the preferences pane and can change it, instead of
/// a tool whose behaviour depends on a probe they cannot see.
enum DefaultTerminalResolver {
    /// Preference order, not install order. Terminal.app is last because it is the one that
    /// cannot be absent — it is the floor, not a choice.
    static let candidates = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.apple.Terminal",
    ]

    /// Injectable so the resolution order is assertable without installing six terminals.
    static func command(
        isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    ) -> String {
        let bundleID = candidates.first(where: isInstalled) ?? "com.apple.Terminal"
        return "open -b \(bundleID) ${cwd}"
    }
}
