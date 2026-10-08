import Foundation

// Submodules through delegation (spec §4.2 step 4, §4.4, §4.5).
//
// The snapshot's tree already pins every submodule: a gitlink is a commit id, and the tree
// check on the host covers it. What the tree does not say is where that commit lives. The
// controller resolves that once, from its own `.git/config`, the superproject's remote (for a
// relative URL) and its `insteadOf` rules, none of which the host has, and sends the result as
// `SnapshotRef.submodules`. The host fetches each pinned commit into a per-repo cache and
// places a `git worktree` of it at the gitlink's path, recursing into nested submodules.
//
// What comes back is the superproject's own files only. A submodule's contents are another
// repository's history; folding them into the superproject's result would turn the gitlink
// into a directory of files on the controller.

/// Controller: every gitlink of a snapshot as a `SubmodulePin`, refusing (before anything is
/// recorded or sent) a submodule the host could not reproduce.
struct SubmoduleScan {
    let git: GitRunner

    /// `gitlinks` are `(path, commit)` of `rev`'s tree in the repository at `dir`. `base` is
    /// what a relative URL is relative to. A populated submodule is checked, then recursed
    /// into; an unpopulated one (never `submodule update`d here) has nothing local to check,
    /// so its pin travels as is and the host resolves anything nested in it on its own.
    func pins(in dir: URL, rev: String, gitlinks: [(path: String, commit: String)], prefix: String = "",
              base: String) throws -> [SubmodulePin] {
        guard !gitlinks.isEmpty else { return [] }
        let declared = Gitmodules(git: git, rev: rev, in: dir)
        let local = localURLs(in: dir)
        var pins: [SubmodulePin] = []
        for link in gitlinks {
            let full = prefix + link.path
            guard let name = declared.name(forPath: link.path),
                  let raw = local[name] ?? declared.urls[name], !raw.isEmpty else {
                throw SyncError.submodule(path: full, problem: .noURL)
            }
            let url = SubmoduleURL.withoutCredentials(expand(SubmoduleURL.resolve(raw, against: base), in: dir))
            pins.append(SubmodulePin(path: full, commit: link.commit, url: url))

            let sub = dir.appendingPathComponent(link.path)
            guard FileManager.default.fileExists(atPath: sub.appendingPathComponent(".git").path) else { continue }
            // `dirty` for a nested submodule's *contents* is left to the recursion, which names
            // the innermost path; a nested one moved off its recorded commit still shows here.
            let status = try git.fields(["status", "--porcelain=v1", "-z", "--untracked-files=normal",
                                         "--ignore-submodules=dirty"], in: sub)
            if !status.isEmpty { throw SyncError.submodule(path: full, problem: .dirty) }
            // Local refs only: asking the remote would put a network round trip (and maybe a
            // credential prompt) in front of every run. A branch or tag fetched from a remote
            // is the evidence the commit exists there; the host's fetch is the final word.
            let holder = try git.text(["for-each-ref", "--count=1", "--contains", link.commit, "--format=%(refname)",
                                       "refs/remotes/", "refs/tags/"], in: sub)
            if holder.isEmpty { throw SyncError.submodule(path: full, problem: .unpushed(commit: link.commit)) }
            let nested = try Self.gitlinks(of: link.commit, in: sub, git: git)
            pins += try self.pins(in: sub, rev: link.commit, gitlinks: nested, prefix: full + "/", base: url)
        }
        return pins
    }

    /// The superproject's own base for relative URLs, as git defines it: the URL of the current
    /// branch's remote (or `origin`), else the superproject's directory.
    func base(of top: URL) -> String {
        let branch = (try? git.text(["symbolic-ref", "-q", "--short", "HEAD"], in: top)) ?? ""
        let remote = branch.isEmpty ? nil : try? git.text(["config", "branch.\(branch).remote"], in: top)
        if let url = try? git.text(["config", "remote.\(remote.flatMap { $0.isEmpty ? nil : $0 } ?? "origin").url"], in: top),
           !url.isEmpty {
            return url
        }
        return top.path
    }

    /// The URLs `git submodule init` wrote to this repository's own config, by name. They win
    /// over `.gitmodules`, as they do for git itself: a user who repointed a submodule locally
    /// expects that URL to be used.
    private func localURLs(in dir: URL) -> [String: String] {
        guard let out = try? git.run(["config", "-z", "--local", "--get-regexp", #"^submodule\..*\.url$"#], in: dir,
                                     accept: [0, 1]) else { return [:] }
        var urls: [String: String] = [:]
        for (key, value) in Gitmodules.entries(out.stdout) where key.hasSuffix(".url") {
            urls[String(key.dropFirst("submodule.".count).dropLast(".url".count))] = value
        }
        return urls
    }

    /// The URL with this machine's `url.<base>.insteadOf` rules applied: the host's git is
    /// isolated from any config, so a rewrite the user relies on (an `ssh` mirror for an
    /// `https` URL) must happen here or not at all.
    private func expand(_ url: String, in dir: URL) -> String {
        guard !url.hasPrefix("-"), let out = try? git.text(["ls-remote", "--get-url", url], in: dir), !out.isEmpty
        else { return url }
        return out
    }

    /// `(path, commit)` of every gitlink in `rev`'s tree. `ls-tree -r` does not descend into a
    /// gitlink, so nested submodules are each repository's own business.
    static func gitlinks(of rev: String, in dir: URL, git: GitRunner) throws -> [(path: String, commit: String)] {
        try git.fields(["ls-tree", "-r", "-z", rev], in: dir).compactMap { entry in
            // <mode> SP <type> SP <object> TAB <path>
            guard entry.hasPrefix("160000 "), let tab = entry.firstIndex(of: "\t") else { return nil }
            let meta = entry[..<tab].split(separator: " ")
            guard meta.count == 3 else { return nil }
            return (String(entry[entry.index(after: tab)...]), String(meta[2]))
        }
    }

    /// The host's view: `gitlinks(of:in:git:)`, but nothing at all, without listing the tree,
    /// when `rev` has no `.gitmodules`. Every apply and every result asks, and a full
    /// `ls-tree -r` of a big repo on each would be paid by the many repos with no submodules.
    /// A gitlink without a `.gitmodules` never gets here: the controller refuses it
    /// (`submodule_no_url`), and placing one would fail the same way.
    static func declaredGitlinks(of rev: String, in dir: URL, git: GitRunner) throws -> [(path: String, commit: String)] {
        guard (try? git.run(["cat-file", "-e", "\(rev):.gitmodules"], in: dir)) != nil else { return [] }
        return try gitlinks(of: rev, in: dir, git: git)
    }

    /// `(path, commit)` of every gitlink in `ls-files -s -z` output.
    static func gitlinks(staged: [String]) -> [(path: String, commit: String)] {
        staged.compactMap { entry in
            // <mode> SP <object> SP <stage> TAB <path>
            guard entry.hasPrefix("160000 "), let tab = entry.firstIndex(of: "\t") else { return nil }
            let meta = entry[..<tab].split(separator: " ")
            guard meta.count == 3 else { return nil }
            return (String(entry[entry.index(after: tab)...]), String(meta[1]))
        }
    }
}

/// A `.gitmodules` as committed in some tree: submodule names by path, and their URLs.
struct Gitmodules {
    private(set) var paths: [String: String] = [:]
    private(set) var urls: [String: String] = [:]

    /// Read from `rev:.gitmodules`; empty when the tree has none (or it does not parse, which
    /// then surfaces as the gitlink having no URL, naming its path).
    init(git: GitRunner, rev: String, in dir: URL) {
        guard let out = try? git.run(["config", "-z", "--blob", "\(rev):.gitmodules", "--get-regexp", #"^submodule\."#],
                                     in: dir, accept: [0, 1]) else { return }
        for (key, value) in Self.entries(out.stdout) {
            let rest = key.dropFirst("submodule.".count)
            if rest.hasSuffix(".path") { paths[String(rest.dropLast(".path".count))] = value }
            if rest.hasSuffix(".url") { urls[String(rest.dropLast(".url".count))] = value }
        }
    }

    func name(forPath path: String) -> String? {
        paths.first { $0.value == path }?.key
    }

    func url(forPath path: String) -> String? {
        name(forPath: path).flatMap { urls[$0] }
    }

    /// `git config -z` output: `key LF value NUL`, repeated. A key's section and variable are
    /// lowercased by git; the subsection (the submodule's name) keeps its case.
    static func entries(_ data: Data) -> [(String, String)] {
        data.split(separator: 0).compactMap { record in
            let text = String(decoding: record, as: UTF8.self)
            guard let lf = text.firstIndex(of: "\n") else { return nil }
            return (String(text[..<lf]), String(text[text.index(after: lf)...]))
        }
    }
}

/// Submodule URLs: git's relative-URL rule, and what the host will fetch from.
enum SubmoduleURL {
    /// `url` made absolute against `base` when it starts `./` or `../`, as `git submodule init`
    /// does: `base` is treated as a directory, each `../` removes one of its components. Works
    /// for scheme URLs, scp-style `host:path` and plain paths alike.
    static func resolve(_ url: String, against base: String) -> String {
        guard url.hasPrefix("./") || url.hasPrefix("../") else { return url }
        var base = base
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var rest = Substring(url)
        while true {
            if rest.hasPrefix("./") {
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("../") {
                rest = rest.dropFirst(3)
                base = parent(of: base)
            } else {
                break
            }
        }
        return base.hasSuffix(":") ? base + rest : base + "/" + rest
    }

    /// `base` without its last component. A scheme URL's host is never removed; an scp-style
    /// `host:repo` becomes `host:`.
    private static func parent(of base: String) -> String {
        let scheme = base.range(of: "://")
        // A scheme URL's slashes before its path (the `//` and the host) are not components.
        let floor = scheme.map { base[$0.upperBound...].firstIndex(of: "/") ?? base.endIndex } ?? base.startIndex
        if let slash = base.lastIndex(of: "/"), slash >= floor {
            return slash == base.startIndex ? "/" : String(base[..<slash])
        }
        if scheme == nil, let colon = base.firstIndex(of: ":") { return String(base[...colon]) }
        return base
    }

    /// Whether git would fetch `url` with its file transport: a `file://` URL, or a path (no
    /// scheme, and no colon before the first slash, which would make it scp-style `host:path`).
    static func isLocal(_ url: String) -> Bool {
        if url.lowercased().hasPrefix("file:") { return true }
        if url.contains("://") { return false }
        guard let colon = url.firstIndex(of: ":") else { return true }
        return url[..<colon].contains("/")
    }

    /// What the host lets a fetch use. Every URL here came over the wire, so it is refused
    /// rather than handed to git when it could be read as an option (`--upload-pack=…`) and
    /// the transport is restricted to the ordinary protocols (no `ext::`, which runs a
    /// command, or `fd::`): a paired controller can already run commands on the host, but a
    /// URL in a `.gitmodules` it synced came from whoever wrote that repository. `file` is
    /// allowed only for the controller's own pins (`fetchEnvironment(allowFile:)`): a nested
    /// `.gitmodules` read on the host gets `remoteProtocols`.
    static let allowedProtocols = "file:git:http:https:ssh"

    /// An http transfer that moves under 1000 bytes/s for 60 s is abandoned. Without it a
    /// hung server held the fetch, the cache lock and the run's slot for `longTimeout` (an
    /// hour), past the controller's own wait for the run to start.
    static let fetchConfig = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=60"]

    /// The environment of every submodule fetch: the allowed transports, and ssh that never
    /// prompts (hostd has no terminal; a passphrase or host-key question would wait forever),
    /// gives up on a connect after 15 s and on a silent server after 45 s (3 keepalives).
    static func fetchEnvironment(allowFile: Bool) -> [String: String] {
        ["GIT_ALLOW_PROTOCOL": allowFile ? allowedProtocols : remoteProtocols,
         "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"]
    }

    static let remoteProtocols = "git:http:https:ssh"

    /// Whether a failed one-commit fetch was the server refusing that request (it will not
    /// hand out an unadvertised object, or cannot do shallow), the only failure a full fetch
    /// can get past. A connection or auth failure would fail the full fetch the same way,
    /// after waiting as long again.
    static func refusedOneCommit(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["unadvertised object", "not our ref", "does not support shallow"].contains { text.contains($0) }
    }

    /// `url` without the credentials it may carry. A token in a local `submodule.*.url`, or
    /// one an `insteadOf` rule adds, would otherwise travel in the pin: over the wire, into the
    /// host's cache name and state, and into every message that quotes the URL. The host
    /// fetches with its own credentials. An http(s) URL loses its whole userinfo (it is only
    /// ever credentials there); any other scheme keeps its user, which names the account (the
    /// `git` of `ssh://git@host/…`), and loses only a `:password`. An scp-style `user@host:path`
    /// cannot hold a password and is left alone.
    /// The line of a failed fetch's stderr that says why. ssh prints its reason first
    /// ("Permission denied (publickey)", "Host key verification failed") and git closes with a
    /// generic "Could not read from remote repository" and advice, so the last line said
    /// nothing. So: ssh's reason, else git's first `fatal:` (joined with the next line when it
    /// ends in a colon, as "unable to connect to <host>:" does), else the last line.
    static func failureDetail(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let reason = lines.first(where: { $0.contains("Permission denied") || $0.contains("Host key") }) { return reason }
        if let i = lines.firstIndex(where: { $0.hasPrefix("fatal:") }) {
            return lines[i].hasSuffix(":") && i + 1 < lines.count ? "\(lines[i]) \(lines[i + 1])" : lines[i]
        }
        return lines.last ?? "git fetch failed"
    }

    static func withoutCredentials(_ url: String) -> String {
        guard let scheme = url.range(of: "://") else { return url }
        let authorityStart = scheme.upperBound
        let authorityEnd = url[authorityStart...].firstIndex(of: "/") ?? url.endIndex
        guard let at = url[authorityStart..<authorityEnd].lastIndex(of: "@") else { return url }
        let userinfo = url[authorityStart..<at]
        let isHTTP = ["http", "https"].contains(url[..<scheme.lowerBound].lowercased())
        let kept = isHTTP ? "" : (userinfo.split(separator: ":", maxSplits: 1).first.map { "\($0)@" } ?? "")
        return String(url[..<authorityStart]) + kept + String(url[url.index(after: at)...])
    }

    /// `text` with the userinfo of every URL in it replaced by `***`, for messages: a host
    /// that predates `withoutCredentials` may still hold a URL with a token, and git quotes the
    /// URL it was given in its own errors.
    static func redacted(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let scheme = rest.range(of: "://") {
            out += rest[..<scheme.upperBound]
            rest = rest[scheme.upperBound...]
            let authorityEnd = rest.firstIndex { $0 == "/" || $0 == " " || $0 == "'" || $0 == "\"" || $0 == "\n" } ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") {
                out += "***"
                rest = rest[at...]
            }
        }
        return out + rest
    }

    static func refusal(_ url: String) -> String? {
        if url.isEmpty || url.hasPrefix("-") || url.contains("\n") || url.contains("\0") {
            return "refused: not a repository URL"
        }
        if url.contains("::") { return "refused: only file, git, http, https and ssh URLs are fetched" }
        return nil
    }

    /// A cache directory name for `url`: readable (its last component) and unique (FNV-1a of
    /// the whole URL, as `Snapshotter.wtKey`; a collision only shares one object store).
    static func cacheName(_ url: String) -> String {
        let last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repo"
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var stem = String((last.hasSuffix(".git") ? String(last.dropLast(4)) : last).map { allowed.contains($0) ? $0 : "-" })
        if stem.isEmpty { stem = "repo" }
        return "\(stem.prefix(64))-\(Snapshotter.wtKey(forPath: url)).git"
    }
}

// MARK: - Host

extension Workspace {
    /// Where this controller's submodule caches live: one bare repository per submodule URL,
    /// beside (not inside) `workspaces/`, so `prune` and `usage`, which walk that directory as
    /// repo roots, never mistake a cache for a repo. Kept across runs, so the next run fetches
    /// nothing it already has; `prune` deletes the ones no checkout uses any more, and
    /// `usage` lists them.
    func submoduleCaches(controller: UUID) -> URL {
        root.appendingPathComponent("submodules/\(controller.uuidString)")
    }

    /// Deletes each of this controller's submodule caches that no checkout has a worktree of
    /// any more, after `prune` deleted checkouts: all of them for a whole prune, and for one
    /// repo's, those only that repo used. A cache another repo's checkout still uses keeps its
    /// worktree record and stays. Under each cache's lock, so a placement in progress (which
    /// fetches and adds its worktree in one hold of that lock) is never caught half done.
    func pruneUnusedSubmoduleCaches(controller: UUID) throws {
        let fm = FileManager.default
        let base = submoduleCaches(controller: controller)
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let cache = base.appendingPathComponent(name)
            try withStore(cache) {
                _ = try? git.run(["worktree", "prune"], in: cache)
                let live = (try? fm.contentsOfDirectory(atPath: cache.appendingPathComponent("worktrees").path)) ?? []
                if live.isEmpty { try? fm.removeItem(at: cache) }
            }
        }
    }

    /// After the superproject's checkout: every gitlink in `top`'s `HEAD`, recursively, at its
    /// commit. The commit is the tree's (already verified), never the pin's; the pin supplies
    /// only the URL. A gitlink with no pin (nested in a submodule the controller never
    /// initialized) falls back to its parent's `.gitmodules`.
    func placeSubmodules(_ ref: SnapshotRef, in top: URL, controller: UUID) throws {
        let pins = Dictionary(ref.submodules.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [String] = []
        try place(in: top, prefix: "", parentURL: nil, pins: pins, caches: submoduleCaches(controller: controller),
                  ignoring: Self.controllerIgnores(top), placed: &placed)
        try sweepStaleSubmodules(in: top, keeping: placed)
    }

    /// `ignoring` config for the controller's excludes, as `finish` wrote them into the slot's
    /// admin dir: what the controller ignores, it ignores inside its submodules too, so their
    /// build output survives `clean` and is not reported as a change.
    static func controllerIgnores(_ slot: URL) -> [String] {
        adminDir(slot).map { ignoring($0.appendingPathComponent("flightdeck-excludes")) } ?? []
    }

    private func place(in dir: URL, prefix: String, parentURL: String?, pins: [String: SubmodulePin], caches: URL,
                       ignoring: [String], placed: inout [String]) throws {
        let links = try SubmoduleScan.declaredGitlinks(of: "HEAD", in: dir, git: git)
        guard !links.isEmpty else { return }
        let declared = Gitmodules(git: git, rev: "HEAD", in: dir)
        for link in links {
            let full = prefix + link.path
            let url: String
            let pinned = pins[full] != nil
            if let pin = pins[full] {
                url = pin.url
            } else if let raw = declared.url(forPath: link.path),
                      let resolved = raw.hasPrefix("./") || raw.hasPrefix("../")
                          ? parentURL.map({ SubmoduleURL.resolve(raw, against: $0) }) : raw {
                url = resolved
            } else {
                throw SyncError.submodule(path: full, problem: .noURL)
            }
            if let why = SubmoduleURL.refusal(url) ?? (pinned || !SubmoduleURL.isLocal(url) ? nil
                    : "refused: a local path from a nested .gitmodules; only the controller's own pins may name one") {
                throw SyncError.submodule(path: full, problem: .fetchFailed(url: url, detail: why))
            }
            try ResultApplier.checkSafe(link.path, under: dir)
            let cache = caches.appendingPathComponent(SubmoduleURL.cacheName(url))
            let sub = dir.appendingPathComponent(link.path, isDirectory: true)
            // Per cache, like the store: two slots placing the same submodule at once would
            // race on its `worktrees/` and on the fetch's lock files.
            try withStore(cache) {
                submoduleFetchHook?(full)
                try fetchIfMissing(link.commit, from: url, into: cache, path: full, allowFile: pinned)
                try placeWorktree(link.commit, at: sub, from: cache, ignoring: ignoring)
            }
            placed.append(full)
            try place(in: sub, prefix: full + "/", parentURL: url, pins: pins, caches: caches, ignoring: ignoring,
                      placed: &placed)
        }
    }

    /// Makes `commit` present in `cache`, fetching only when it is not: a shallow fetch of that
    /// one commit first (most servers allow it, and a big submodule's full history can be
    /// gigabytes), then everything the remote advertises for a server that refuses. The commit
    /// is then kept under `refs/fd/pins/`, so `gc` cannot drop what a slot has checked out.
    func fetchIfMissing(_ commit: String, from url: String, into cache: URL, path: String, allowFile: Bool) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cache.path) {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try git.run(["init", "-q", "--bare", cache.path])
        }
        func present() -> Bool { (try? git.run(["cat-file", "-e", "\(commit)^{commit}"], in: cache)) != nil }
        if !present() {
            Self.clearStaleLocks(in: cache)
            let env = SubmoduleURL.fetchEnvironment(allowFile: allowFile)
            /// false: the server refused exactly this request (asked only when `refusable`).
            func fetch(_ args: [String], refusable: Bool) throws -> Bool {
                do {
                    try git.run(SubmoduleURL.fetchConfig + ["fetch", "-q", "--no-write-fetch-head"] + args,
                                in: cache, env: env, timeout: GitRunner.longTimeout)
                    return true
                } catch GitError.failed(_, _, let stderr) {
                    if refusable && SubmoduleURL.refusedOneCommit(stderr) { return false }
                    throw SyncError.submodule(path: path, problem: .fetchFailed(url: url, detail: SubmoduleURL.failureDetail(stderr)))
                } catch GitError.timedOut(_, let seconds) {
                    throw SyncError.submodule(path: path, problem: .fetchFailed(url: url, detail: "timed out after \(Int(seconds))s"))
                }
            }
            // The one commit. Only the server refusing exactly that earns the full fetch; any
            // other failure (unreachable, auth) is final, rather than paid for twice.
            _ = try fetch(["--no-tags", "--depth=1", url, commit], refusable: true)
            if !present() {
                let shallow = (try? git.text(["rev-parse", "--is-shallow-repository"], in: cache)) == "true"
                _ = try fetch((shallow ? ["--unshallow"] : []) +
                              [url, "+refs/heads/*:refs/fd/remote/heads/*", "+refs/tags/*:refs/fd/remote/tags/*"],
                              refusable: false)
                guard present() else { throw SyncError.submodule(path: path, problem: .missingCommit(url: url, commit: commit)) }
            }
        }
        try git.run(["update-ref", "refs/fd/pins/\(commit)", commit], in: cache)
    }

    /// The lock files a killed fetch leaves in a cache (`shallow.lock`, a ref's `.lock`), each
    /// of which would fail every later fetch into it. Only called under the cache's lock, and
    /// one hostd owns the state root, so any lock found here is stale.
    static func clearStaleLocks(in cache: URL) {
        let fm = FileManager.default
        for name in ["shallow.lock", "packed-refs.lock", "config.lock", "HEAD.lock"] {
            try? fm.removeItem(at: cache.appendingPathComponent(name))
        }
        guard let walker = fm.enumerator(at: cache.appendingPathComponent("refs"), includingPropertiesForKeys: nil) else { return }
        for case let file as URL in walker where file.pathExtension == "lock" { try? fm.removeItem(at: file) }
    }

    /// `sub` as a worktree of `cache` at `commit`. One already there is moved in place
    /// (`checkout --force`, then `clean -fd`, never `-x`, so the submodule's ignored build
    /// output survives as the superproject's does); anything else there is replaced.
    private func placeWorktree(_ commit: String, at sub: URL, from cache: URL, ignoring: [String]) throws {
        let fm = FileManager.default
        if let admin = Self.adminDir(sub), admin.standardizedFileURL.path.hasPrefix(cache.standardizedFileURL.path + "/worktrees/"),
           fm.fileExists(atPath: admin.path) {
            // Both locks are held (the slot's and the cache's): a leftover index.lock is stale.
            try? fm.removeItem(at: admin.appendingPathComponent("index.lock"))
            if (try? git.run(["checkout", "-q", "--force", "--detach", commit], in: sub, timeout: GitRunner.longTimeout)) != nil,
               (try? git.run(ignoring + ["clean", "-fdq"], in: sub, timeout: GitRunner.longTimeout)) != nil,
               (try? git.text(["rev-parse", "HEAD"], in: sub)) == commit {
                return
            }
        }
        try? fm.removeItem(at: sub)
        try fm.createDirectory(at: sub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git.run(["worktree", "prune"], in: cache)
        try git.run(["worktree", "add", "-q", "--detach", "--force", sub.path, commit], in: cache, timeout: GitRunner.longTimeout)
    }

    /// Removes submodules an earlier apply placed in this slot that this one did not. A
    /// superproject checkout leaves a populated submodule directory behind when the gitlink
    /// goes away (git will not delete another repository), and the next result's `add -A`
    /// would then commit it back as a gitlink nobody asked for. Recorded in the slot's admin
    /// dir, because only Flight Deck knows which nested repositories it put there.
    private func sweepStaleSubmodules(in top: URL, keeping placed: [String]) throws {
        guard let admin = Self.adminDir(top) else { return }
        let record = admin.appendingPathComponent("flightdeck-submodules")
        let fm = FileManager.default
        let before = ((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        if before.isEmpty && placed.isEmpty { return }   // the usual repo: no submodules, then or now
        let keep = Set(placed)
        // Deepest first, so a parent's removal never runs before its child's check.
        for stale in before.filter({ !keep.contains($0) }).sorted(by: { $0.count > $1.count }) {
            let dir = top.appendingPathComponent(stale)
            guard (try? ResultApplier.checkSafe(stale, under: top)) != nil,
                  (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(".git").path))?[.type] as? FileAttributeType
                    == .typeRegular else { continue }
            // The repository that contains it now (the superproject, or a submodule still
            // placed above it) may track files at that path: then only the link goes, and the
            // tracked files stay where its checkout put them.
            let owner = placed.filter { stale.hasPrefix($0 + "/") }.max(by: { $0.count < $1.count })
            let ownerDir = owner.map { top.appendingPathComponent($0) } ?? top
            let relative = owner.map { String(stale.dropFirst($0.count + 1)) } ?? stale
            let tracked = (try? git.fields(["ls-files", "-z", "--", relative], in: ownerDir)) ?? []
            if tracked.isEmpty { try? fm.removeItem(at: dir) } else { try? fm.removeItem(at: dir.appendingPathComponent(".git")) }
        }
        try Data(placed.map { $0 + "\n" }.joined().utf8).write(to: record)
    }

    /// The top-level submodules a run changed: moved off their pinned commit, or with
    /// uncommitted or untracked files (a nested one's changes show in its parent's status).
    /// For the run's output, at exit: those changes stay on the host. Best effort; a submodule
    /// git cannot read is simply not reported.
    public func submoduleChanges(lease: CheckoutLease) async -> [String] {
        (try? await GitRunner.offload { [git] () -> [String] in
            let fm = FileManager.default
            let ignoring = Self.controllerIgnores(lease.path)
            return try SubmoduleScan.declaredGitlinks(of: lease.ref.commit, in: lease.path, git: git).compactMap { link in
                let sub = lease.path.appendingPathComponent(link.path)
                guard fm.fileExists(atPath: sub.appendingPathComponent(".git").path) else { return nil }
                let head = try? git.text(["rev-parse", "HEAD"], in: sub)
                let status = (try? git.fields(ignoring + ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: sub)) ?? []
                return head != link.commit || !status.isEmpty ? link.path : nil
            }
        }) ?? []
    }

    /// Pathspecs for the result's `add -A` that leave every gitlink of the snapshot alone: the
    /// index keeps the snapshot's pin, and nothing inside a submodule is staged even if the run
    /// deleted its `.git` link (which would otherwise make `add` take its files as the
    /// superproject's).
    func resultPathspecs(snapshot commit: String, in dir: URL) throws -> [String] {
        let links = try SubmoduleScan.declaredGitlinks(of: commit, in: dir, git: git)
        guard !links.isEmpty else { return [] }
        return ["--", "."] + links.map { ":(top,literal,exclude)\($0.path)" }
    }
}
