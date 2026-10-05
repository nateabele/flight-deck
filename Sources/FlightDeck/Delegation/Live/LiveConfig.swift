import Foundation
import HostKit

/// `DelegateConfigLoading` over C4's `DelegateConfigParser` and `RecipeWriter`.
struct LiveConfigLoader: DelegateConfigLoading {
    /// Each paired host's platform ("macOS", "Linux") by name, when known: `recipe check`
    /// refuses a `screen` recipe on a Linux host only if it can tell.
    var platforms: () -> [String: String] = { [:] }

    func load(worktree: URL) throws -> DelegateConfig? {
        try DelegateConfigParser.load(projectRoot: worktree)?.config
    }

    func add(_ recipe: Recipe, named name: String, worktree: URL) throws {
        try RecipeWriter.add(name: name, recipe: recipe, projectRoot: worktree)
    }

    /// Errors and warnings both, each naming its line: `recipe check` is the one place a
    /// warning (an unknown key, a route no shim can intercept) is ever shown.
    func problems(in config: DelegateConfig, hosts: [String]) -> [String] {
        var known = platforms()
        for host in hosts where known[host] == nil { known[host] = "" }
        return config.validate(hosts: known).map(\.description)
    }
}

/// `WorktreeLocating` through C2's `GitRunner`, off the main actor: its timeout, its pipe
/// handling and its environment (no inherited `GIT_DIR` redirecting us into another repo).
struct LiveWorktreeLocator: WorktreeLocating {
    var git = GitRunner()

    func locate(cwd: URL) async throws -> (worktree: URL, subdir: String) {
        let git = git
        let lines = try await offloaded {
            try git.run(["rev-parse", "--show-toplevel", "--show-prefix"], in: cwd).stdout
        }
        let fields = String(decoding: lines, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let root = fields.first, !root.isEmpty else {
            throw DelegationError(code: "not_a_repo", message: "\(cwd.path) is not in a git worktree")
        }
        let prefix = fields.count > 1 ? fields[1] : ""
        return (URL(fileURLWithPath: root), prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
    }

    func ignored(_ paths: [String], in worktree: URL) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let git = git
        let out = try? await offloaded {
            try git.run(["check-ignore", "-z", "--stdin"], in: worktree,
                        input: Data(paths.joined(separator: "\0").utf8 + [0]), accept: [0, 1]).stdout
        }
        return Set((out ?? Data()).split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }
}
