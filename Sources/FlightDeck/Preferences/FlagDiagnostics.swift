import Foundation

/// Cross-flag checks that the parser cannot make, because they depend on the resolved
/// set rather than on the token stream. Everything here is a warning: the catalog is a
/// snapshot, and blocking on it would be worse than being wrong about it.
///
/// Single-flag concerns (unknown flags, duplicates, missing values) live in
/// `ClaudeFlagParser` and are not repeated here.
enum FlagDiagnostics {
    static func validate(_ flags: FlagSet) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        if flags.values["--dangerously-skip-permissions"] != nil {
            diagnostics.append(.warning(
                "Every new session will bypass all permission checks. Recommended only for sandboxes with no internet access."
            ))
        }

        if flags.values["--tmux"] != nil, flags.values["--worktree"] == nil {
            diagnostics.append(.warning("--tmux requires --worktree; claude will reject it on its own."))
        }

        // --tmux implies --worktree is expected and intentional, so only warn about the
        // working-directory move when --worktree shows up on its own.
        if flags.values["--worktree"] != nil, flags.values["--tmux"] == nil {
            diagnostics.append(.warning(
                "--worktree moves the session's working directory out of the project root, so its transcript and sidebar grouping follow the worktree."
            ))
        }

        return diagnostics
    }
}
