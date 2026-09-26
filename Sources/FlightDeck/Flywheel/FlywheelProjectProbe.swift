import Foundation

/// Whether a project directory is a flywheel project, and what one-time setup
/// (Agent-Mail guard hook, beads-sync hook) it still needs.
struct FlywheelStatus: Equatable {
    var hasBeads: Bool
    var hasAgentMailMarker: Bool
    var guardInstalled: Bool
    var beadsSyncHooksInstalled: Bool

    var isFlywheelProject: Bool { hasBeads || hasAgentMailMarker }
    var needsSetup: Bool { isFlywheelProject && !(guardInstalled && beadsSyncHooksInstalled) }
}

/// Detects flywheel status by inspecting marker files under a repo root. Pure and
/// read-only: never mutates the filesystem, never shells out.
enum FlywheelProjectProbe {
    private static let guardMarkers = ["agent-mail", "50-agent-mail"]
    private static let beadsSyncMarker = "br sync"

    static func status(of repo: URL, fileManager: FileManager = .default) -> FlywheelStatus {
        let hasBeads = isDirectory(repo.appendingPathComponent(".beads"), fileManager: fileManager)
        let hasAgentMailMarker = isFile(repo.appendingPathComponent(".agent-mail.yaml"), fileManager: fileManager)

        let hookContents = contents(of: repo.appendingPathComponent(".git/hooks/pre-commit"), fileManager: fileManager)
        let guardInstalled = hookContents.map { contents in guardMarkers.contains { contents.contains($0) } } ?? false
        let beadsSyncHooksInstalled = beadsSyncScriptInstalled(
            repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit"), fileManager: fileManager
        )

        return FlywheelStatus(
            hasBeads: hasBeads,
            hasAgentMailMarker: hasAgentMailMarker,
            guardInstalled: guardInstalled,
            beadsSyncHooksInstalled: beadsSyncHooksInstalled
        )
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    private static func isFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return !isDir.boolValue
    }

    private static func contents(of url: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Beads-sync lives as its own script under `hooks.d/pre-commit/` (dispatched by `am`'s
    /// Python chain-runner), never appended to `pre-commit` itself — see `FlywheelSetup`.
    /// Scans the directory for any file containing the marker rather than requiring the
    /// canonical filename, so a manually-renamed install still counts.
    private static func beadsSyncScriptInstalled(_ hooksDDir: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(at: hooksDDir, includingPropertiesForKeys: nil) else {
            return false
        }
        return entries.contains { entry in
            contents(of: entry, fileManager: fileManager)?.contains(beadsSyncMarker) ?? false
        }
    }
}
