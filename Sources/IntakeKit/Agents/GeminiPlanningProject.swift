import Foundation

/// The agy project every read-only Gemini planning seat runs under (`agy --project`): the one
/// place Flight Deck says what a planning seat may read.
///
/// Why a project. A headless `agy -p` cannot ask for permission, so every tool the permission
/// rules do not already cover is auto-denied — and a denied tool ENDS the turn with no answer.
/// From agy 1.3.6 (probed 2026-10-15) that covers every shell command, even `ls` inside the
/// workspace, and a `view_file` outside the workspace (`read_file`), so a seat that tried to
/// look at AGENTS.md's neighbour, another repository or a directory listing lost its turn.
/// agy's settings.json is the operator's; a project file is separate and additive: a new file
/// under `~/.gemini/config/projects/` that only runs launched with `--project` read, so the
/// operator's own `agy` sessions are untouched. (Settings in a workspace's `.agents/` and a
/// HOME override were probed and don't work: the first is ignored, the second signs agy out.)
///
/// Allow rules are `permissionGrants.permissionGrants.allow` — `read_file(<path prefix>)` and
/// `command(<binary [subcommand]>)`, matched per simple command so `cd x && ls | head` works.
/// Deny rules beat allow rules anywhere they come from, and a denied rule returns an error to
/// the model instead of ending its turn (probed), so every writer the seat might reach for is
/// denied by name. `--sandbox` is not used: it is NOT a write boundary (`sed -i` inside the
/// workspace ran under it, probed), and on 1.3.6 it hides every directory outside the project
/// from shell commands, so a seat could not `ls` another repository. That is also why
/// `sed`/`find`/`awk` are denied rather than allowed.
public enum GeminiPlanningProject {
    public static let id = "flight-deck-planning"
    public static let displayName = "Flight Deck planning (read-only)"

    /// Binaries that only read. Never one that can write by itself (`sed -i`, `find -delete`,
    /// `tee`, `awk` with redirects), and never `xargs`/`env`/`sh`, which run anything.
    /// The filters a pipeline ends in (`rg … | cut -f1 | jq …`) are here too: a command the rules
    /// leave out is auto-denied and ends the turn, which is how a Polish round was lost to
    /// `grep … | sort | uniq -c` (2026-10-16).
    static let readCommands = ["cd", "echo", "pwd", "ls", "cat", "head", "tail", "wc", "stat", "file", "du", "tree", "rg", "grep",
                               "cut", "tr", "nl", "comm", "diff", "jq", "column", "basename", "dirname", "realpath", "printf",
                               "date", "which",
                               "git log", "git show", "git diff", "git status", "git ls-files", "git rev-parse", "git blame",
                               "br list", "br show", "br graph", "br ready"]

    /// Writers and runners, denied by name so a try is an error the seat reads, not a turn lost
    /// to an auto-deny. The tool rules (`write_file`) cover agy's own editors. `sort` and `uniq`
    /// are here, not with the readers: given a file to write (`sort -o`, `uniq in out`), they do.
    static let deniedCommands = ["rm", "mv", "cp", "touch", "mkdir", "rmdir", "tee", "chmod", "chown", "ln", "dd", "truncate",
                                 "sed", "awk", "find", "xargs", "sh", "bash", "zsh", "env", "curl", "wget",
                                 "sort", "uniq", "python", "python3", "perl", "node", "ruby", "osascript", "open", "patch",
                                 "install", "make", "kill", "pkill",
                                 "git add", "git commit", "git checkout", "git switch", "git reset", "git restore", "git clean",
                                 "git push", "git pull", "git fetch", "git merge", "git rebase", "git stash", "git apply",
                                 "git config", "git tag", "git branch", "git rm", "git mv", "git cherry-pick", "git revert",
                                 "br create", "br update", "br close", "br reopen", "br delete", "br dep", "br label", "br comments",
                                 "br sync", "br defer", "br undefer", "br q", "br init"]

    /// Reads anywhere — the plan files, the task-graph snapshot, AGENTS.md and README under the
    /// intake's directories, and the project's source or a sibling repository — exactly the
    /// reach a Claude seat's `Read`/`Glob`/`Grep` have. Writes nowhere.
    static let allow = ["read_file(/)"] + readCommands.map { "command(\($0))" }
    static let deny = ["write_file(/)"] + deniedCommands.map { "command(\($0))" }

    /// The project file's bytes — the shape agy itself writes for a project (`id`, `name`,
    /// `projectResources`) plus the grants block. Sorted keys so the bytes are stable and an
    /// unchanged file is never rewritten.
    public static func fileContents() -> Data {
        let file: [String: Any] = [
            "id": id, "name": displayName, "projectResources": [String: Any](),
            "permissionGrants": ["permissionGrants": ["allow": allow, "deny": deny], "v2Migrated": true] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    /// `~/.gemini/config/projects/flight-deck-planning.json`
    public static func fileURL(home: URL) -> URL {
        home.appendingPathComponent(".gemini/config/projects/\(id).json")
    }

    /// Writes the project file if it is missing or differs, so a seat's first run — and any run
    /// after the operator hand-edited or deleted it — finds the current rules. Best effort: a
    /// home without `~/.gemini` (agy never run) is skipped, since agy signs in before it reads
    /// anything and there is nothing to run yet; a failed write leaves the seat to fail as a
    /// denied read, which the diagnosis names. Returns whether the file is in place.
    @discardableResult
    public static func install(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: home.appendingPathComponent(".gemini").path) else { return false }
        let url = fileURL(home: home), bytes = fileContents()
        if let existing = try? Data(contentsOf: url), existing == bytes { return true }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
