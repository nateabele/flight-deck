import Foundation

/// The §5 missing-file heuristic: a delegated run failed, and its output names a file that
/// exists here but is ignored and so was never synced (`.env`, a local config). Without this
/// the agent sees `No such file or directory: .env` from a machine it cannot look at, and
/// "fixes" it by creating a fresh `.env` on the host by hand, or gives up on delegating.
///
/// Deliberately narrow, because a wrong hint sends the agent chasing a file that was never
/// the problem: it fires only on a failed run, only for a path that exists locally, only when
/// git says it is ignored, and only when it was not already sent with `--include`.
enum MissingFileHint {
    /// How much of the tail of a run's stderr is scanned. The error that names the missing
    /// file is almost always among the last lines; scanning a whole build log would match
    /// paths that were only being echoed.
    static let tailBytes = 16 * 1024

    /// The one-line hint, without the `flightdeck: ` the CLI prints in front of it.
    static func message(for path: String) -> String {
        "\(path) is ignored locally and wasn't sent — rerun with --include \(path) or add it to delegate.toml"
    }

    /// The first path in `tail` that passes every check, as a worktree-relative path.
    ///
    /// - Parameters:
    ///   - worktreeName: the worktree's basename, which the host's checkout directory also
    ///     carries (§4.1). An absolute host path is cut after it to get back to a relative one.
    ///   - subdir: the run's subdirectory, which a bare relative path in the output is
    ///     relative to.
    ///   - sent: the `include` paths that were synced, which are by definition not missing.
    ///   - ignored: answers which of the candidates git ignores in `worktree`.
    static func hint(tail: String, worktree: URL, worktreeName: String, subdir: String, sent: Set<String>,
                     ignored: (_ paths: [String], _ worktree: URL) -> Set<String>) -> String? {
        let fm = FileManager.default
        var seen = Set<String>()
        let existing = candidates(in: tail, worktreeName: worktreeName, subdir: subdir).filter { path in
            guard seen.insert(path).inserted, !sent.contains(path) else { return false }
            return fm.fileExists(atPath: worktree.appendingPathComponent(path).path)
        }
        guard !existing.isEmpty else { return nil }
        let ignoredPaths = ignored(existing, worktree)
        return existing.first { ignoredPaths.contains($0) }.map(message(for:))
    }

    /// Every token in `text` that reads as a path, made relative to the worktree root.
    /// Tokens are split on whitespace and on the quoting and punctuation compilers and shells
    /// wrap paths in (`'…'`, `"…"`, `(…)`, `path:12:`), so `open('.env')` and `.env: No such
    /// file` both yield `.env`.
    static func candidates(in text: String, worktreeName: String, subdir: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"`()[]{}<>,;:=|"))
        return text.components(separatedBy: separators).compactMap { raw in
            var token = raw
            while let last = token.last, ".!?".contains(last), token.count > 1, token != ".." {
                // A sentence's full stop is not part of the path, but a dotfile's leading dot
                // is: only trailing punctuation is trimmed.
                token.removeLast()
            }
            guard !token.isEmpty, token != ".", token != "..", token.contains(where: \.isLetter) else { return nil }
            if token.hasPrefix("/") {
                // A host path: everything after the checkout's `/<worktreeName>/`.
                guard let range = token.range(of: "/\(worktreeName)/", options: .backwards) else { return nil }
                return normalized(String(token[range.upperBound...]))
            }
            let relative = subdir.isEmpty ? token : subdir + "/" + token
            return normalized(relative)
        }
    }

    /// `a/./b` → `a/b` and `a/../b` → `b`; nil when it climbs out of the worktree, which the
    /// heuristic has no business suggesting.
    private static func normalized(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}
