import Foundation

/// Which `~/.claude/projects` directories belong to the projects open in the sidebar.
///
/// **Why this is not a prefix match.** `ClaudeSession.encodedProjectDirName` replaces every
/// non-ASCII-alphanumeric UTF-16 code unit with `-`, which is lossy: nothing can turn
/// `-w-flight-deck` back into a path. The tempting shortcut is to accept every directory
/// whose name starts with the project's encoding — and that is wrong in a way that is
/// invisible until someone notices results from the wrong repo. `/w/flight-deck` encodes to
/// `-w-flight-deck`, which is a genuine prefix of `/w/flight-deck-old`'s encoding, so the
/// shortcut folds a neighbouring project's whole history into this one's search results.
///
/// So the direction is reversed: enumerate paths that really exist on disk — the project
/// and its worktrees — encode each, and accept only exact name matches.
///
/// Pure. `listing` and `exists` are injected so the rules above are testable without a
/// filesystem.
enum SearchCorpus {
    /// A transcript directory and the sidebar project that owns it.
    struct Entry: Equatable {
        let projectPath: String
        let directory: URL
    }

    /// Where a project's own agents put worktrees. Both are real: `EnterWorktree` uses
    /// `.claude/worktrees`, and the superpowers skills use `.superpowers/worktrees`.
    private static let worktreeRoots = [".claude/worktrees", ".superpowers/worktrees"]

    /// The literal directories this project owns: itself, plus one per existing worktree.
    /// Kept separate from `transcriptDirectoryNames` because encoding is one-way — see this
    /// type's doc comment — so a caller that needs the literal path *back* (not just whether
    /// an encoded name matches something) has to start from here rather than decode a name.
    static func candidateWorkingDirectories(
        forProjectAt path: String,
        listing: (String) -> [String]
    ) -> [String] {
        var paths = [path]
        for root in worktreeRoots {
            let rootPath = (path as NSString).appendingPathComponent(root)
            for child in listing(rootPath) {
                paths.append((rootPath as NSString).appendingPathComponent(child))
            }
        }
        return paths
    }

    /// The encoded directory names this project owns: itself, plus one per existing
    /// worktree. Exact names — never prefixes.
    static func transcriptDirectoryNames(
        forProjectAt path: String,
        listing: (String) -> [String]
    ) -> [String] {
        candidateWorkingDirectories(forProjectAt: path, listing: listing)
            .map(ClaudeSession.encodedProjectDirName(for:))
    }

    /// Every in-scope transcript directory across `paths`, each tagged with its project.
    ///
    /// Deduplicated by resolved directory, not by project: two sidebar entries can resolve
    /// to the same directory (nested projects, or the same folder added by two paths that
    /// normalise together), and indexing it twice would double every hit inside it. First
    /// project named wins, so the order of `paths` decides the owner — which matches the
    /// sidebar's own order.
    static func directories(
        forProjects paths: [String],
        projectsRoot: URL,
        listing: (String) -> [String],
        exists: (String) -> Bool
    ) -> [Entry] {
        var seen: Set<URL> = []
        var entries: [Entry] = []

        for path in paths {
            for name in transcriptDirectoryNames(forProjectAt: path, listing: listing) {
                let directory = projectsRoot.appendingPathComponent(name, isDirectory: true)
                guard exists(directory.path), seen.insert(directory).inserted else { continue }
                entries.append(Entry(projectPath: path, directory: directory))
            }
        }
        return entries
    }

    /// The production `listing`: a directory that is absent or unreadable simply has no
    /// worktrees, which is the overwhelmingly common case and not an error.
    static func defaultListing(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
