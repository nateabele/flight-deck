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

    /// Where the usage mod writes one file per tab (Flight Control L3-U). Beside the hook-event
    /// directory and split by build for the same reason: a debug build must never read the
    /// release fleet's meters as its own.
    static var usageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("usage-\(buildTag)", isDirectory: true)
    }

    /// Where Flight Deck runs its plugin from, when the engine writes into plugin folders.
    ///
    /// Claude lays its type declarations into `<plugin>/.claude-plugin/types/` every time it loads
    /// a `--plugin-dir` folder the user owns (probe 1, Outcome 3C). The bundle copy lives inside
    /// `/Applications/Flight Deck.app`, which the user owns and which is code-signed: that write
    /// would invalidate the signature on the first claude tab. So the bundle is the source and
    /// this copy is what claude is pointed at.
    static var materializedDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("claude-plugin-\(buildTag)", isDirectory: true)
    }

    /// The destination's record of the paths Flight Deck itself copied there. Pruning is driven
    /// by this list, never by a scan of the destination: the engine writes its own files into the
    /// folder (a root `tsconfig.json`, `.claude-plugin/types/`), and a scan-based prune deleted
    /// them on every claude launch for the engine to write back.
    static let materializeManifestName = ".flightdeck-materialized"

    /// Mirrors `source` into `destination`: copies new and changed files, removes files Flight
    /// Deck copied earlier that the source no longer ships, and never touches
    /// `.claude-plugin/types/` in either folder: that is the engine's. The source's copy matters
    /// too — `claude plugin test` on the repo folder writes types there, they would ship in the
    /// bundle, and copying them would overwrite the engine's own declarations in the destination
    /// with a stale version's.
    /// Compares bytes rather than dates, and sets permissions only when they differ, so a
    /// reinstall of the same build touches nothing — a rewrite (or even a chmod, which bumps
    /// ctime) risks hot-reloading the module in every open claude tab for no reason.
    @discardableResult
    static func materialize(from source: URL, to destination: URL = materializedDirectory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifestURL = destination.appendingPathComponent(materializeManifestName)
        // First run (no manifest) deletes nothing: we cannot know what is ours.
        let previous: Set<String> = (try? String(contentsOf: manifestURL, encoding: .utf8))
            .map { Set($0.split(separator: "\n").map(String.init)) } ?? []
        let shipped = try relativeFiles(under: source).filter {
            !$0.hasPrefix(".claude-plugin/types/") && $0 != materializeManifestName
        }
        for path in shipped {
            let from = source.appendingPathComponent(path), to = destination.appendingPathComponent(path)
            let bytes = try Data(contentsOf: from)
            if (try? Data(contentsOf: to)) != bytes {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: to, options: .atomic)
            }
            let want = try fm.attributesOfItem(atPath: from.path)[.posixPermissions] as? NSNumber
            let have = try? fm.attributesOfItem(atPath: to.path)[.posixPermissions] as? NSNumber
            if let want, want != have {
                try fm.setAttributes([.posixPermissions: want], ofItemAtPath: to.path)
            }
        }
        for path in previous.subtracting(shipped) where !path.hasPrefix(".claude-plugin/types/") && path != materializeManifestName {
            try? fm.removeItem(at: destination.appendingPathComponent(path))
        }
        let manifest = Data((shipped.sorted().joined(separator: "\n") + "\n").utf8)
        if (try? Data(contentsOf: manifestURL)) != manifest {
            try manifest.write(to: manifestURL, options: .atomic)
        }
        return destination
    }

    private static func relativeFiles(under root: URL) throws -> Set<String> {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: Set<String> = []
        for case let url as URL in walker {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            out.insert(String(full.dropFirst(base.count + 1)))
        }
        return out
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

    /// The whole composition `SessionStore.options(for:project:)` needs: unwrap `.claude`,
    /// find the plugin in `bundle`, inject, re-wrap. Pulled out as a pure function — rather
    /// than left inline at the one call site — so a test can drive it with a bundle that
    /// actually carries the plugin (`Bundle(for: Self.self)` in the test target does; the
    /// real call site's `Bundle.main` is the `xctest` tool under `scripts/test-unit.sh` and
    /// never would). `.codex` and a bundle without the plugin both pass `options` through
    /// unchanged.
    static func applying(to options: AgentOptions, bundle: Bundle, pluginDestination: URL = materializedDirectory) -> AgentOptions {
        guard case .claude(let flags) = options, let plugin = directory(bundle: bundle) else {
            return options
        }
        // Outcome 3C: run the owned copy, never the signed bundle. A failed copy falls back to
        // the bundle — a broken signature is recoverable, a claude tab with no hooks is the
        // silent failure `record.sh`'s header warns about.
        do {
            let runnable = try materialize(from: plugin, to: pluginDestination)
            return .claude(injecting(into: flags, pluginDirectory: runnable))
        } catch {
            NSLog("[ClaudePluginLocation] failed to materialize plugin from \(plugin.path) to \(pluginDestination.path): \(error) — falling back to signed bundle")
            return .claude(injecting(into: flags, pluginDirectory: plugin))
        }
    }
}
