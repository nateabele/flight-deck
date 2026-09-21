import Foundation

/// Where Flight Deck's own Claude Code plugin lives, and where its sessions report to.
///
/// `bundle` is a parameter rather than `Bundle.main` because under `scripts/test-unit.sh`
/// the main bundle is the `xctest` tool, not `Flight Deck.app` — the same seam
/// `SessionDaemon.bundledBinary` exists for.
enum ClaudePluginLocation {
    /// Separates a debug build's event stream from the real fleet's. Sharing one directory
    /// is the trap `sessions.json` already has.
    static var buildTag: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    static func directory(bundle: Bundle) -> URL? {
        guard let url = bundle.url(forResource: "ClaudePlugin", withExtension: nil),
              FileManager.default.fileExists(
                  atPath: url.appendingPathComponent("hooks/hooks.json").path
              )
        else { return nil }
        return url
    }

    static var eventDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("hook-events-\(buildTag)", isDirectory: true)
    }

    /// Appends the bundled plugin to whatever `--plugin-dir` entries the user already set.
    /// Idempotent: a resume re-resolves options and must not accumulate duplicates.
    static func injecting(into flags: FlagSet, pluginDirectory: URL) -> FlagSet {
        var out = flags
        var items: [String]
        if case .list(let existing)? = flags.values["--plugin-dir"] {
            items = existing
        } else {
            items = []
        }
        let path = pluginDirectory.path
        guard !items.contains(path) else { return out }
        items.append(path)
        out.values["--plugin-dir"] = .list(items)
        return out
    }
}
