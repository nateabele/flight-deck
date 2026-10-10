import Foundation

// The sync engine's only door to git (spec §4): the `git` CLI through `posix_spawn`, never
// libgit2, so the controller and both hosts run the same tool the user's own repo was made
// with. Every call is synchronous and may block for as long as git takes (a first sync of a big
// repo is minutes), which is why `Snapshotter`, `BundleMaker`, `Workspace` and `ResultApplier`
// hop off the caller's executor before using it (`GitRunner.offload`).

/// A git invocation that did not succeed.
public enum GitError: Error, Equatable, CustomStringConvertible {
    /// No `git` executable on `PATH` or in the usual install locations.
    case notFound
    case failed(args: [String], status: Int32, stderr: String)
    case timedOut(args: [String], seconds: Double)
    /// No output on stdout or stderr for `seconds` (`run`'s `stall`), and killed for it.
    case stalled(args: [String], seconds: Double)

    public var description: String {
        switch self {
        case .notFound: return "git is not installed"
        case .failed(let args, let status, let stderr):
            return "git \(args.joined(separator: " ")) exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut(let args, let seconds):
            return "git \(args.joined(separator: " ")) timed out after \(Int(seconds))s"
        case .stalled(let args, let seconds):
            return "git \(args.joined(separator: " ")) made no progress for \(Int(seconds))s"
        }
    }
}

/// The sync engine's own refusals. `description` is the text after `flightdeck: ` on the CLI;
/// `code` is the host error code the router replies with (C0 amendment A5).
public enum SyncError: Error, Equatable, CustomStringConvertible {
    case lfsUnsupported
    /// A submodule this sync cannot reproduce on the host, by its path in the superproject.
    case submodule(path: String, problem: SubmoduleProblem)
    /// The worktree has no commit yet, so there is no history to sync against.
    case unbornHead
    /// The checkout's `HEAD^{tree}` is not the tree the controller snapshotted (§4.4).
    case treeMismatch(expected: String, actual: String)
    /// A received bundle does not carry the snapshot commit it was sent for.
    case bundleLacksSnapshot(String)
    /// A wire-supplied name (repo root, wt-key, worktree name, run id) that would escape its
    /// directory or make an invalid ref.
    case invalidName(String)
    /// A fetch glob matched a tracked path; tracked files come back through the patch (§4.5).
    case artifactTracked(glob: String, path: String)
    /// `exec` named a worktree this host has never checked out.
    case noCheckout
    /// `prune` would delete a checkout a run or service still holds.
    case runActive
    /// The run's result is unknown, past its TTL, or already acked: distinct from "the run
    /// changed nothing" (nil), so a lost result never reads as an empty one.
    case resultExpired
    /// A result path that is absolute, has a `.`, `..` or `.git` component, or sits under a
    /// symlink: writing it could escape the worktree or plant a git hook.
    case unsafePath(String)
    /// git older than 2.40, which lacks `merge-tree --write-tree --merge-base`.
    case gitTooOld(String)

    public var code: String {
        switch self {
        case .lfsUnsupported: return "lfs_unsupported"
        case .submodule(_, let problem): return problem.code
        case .treeMismatch: return "tree_mismatch"
        case .noCheckout: return "no_checkout"
        case .runActive: return "run_active"
        case .resultExpired: return "result_expired"
        case .gitTooOld: return "git_too_old"
        case .unsafePath: return "unsafe_path"
        case .unbornHead, .bundleLacksSnapshot, .invalidName, .artifactTracked: return "unsupported"
        }
    }

    public var description: String {
        switch self {
        case .lfsUnsupported: return "LFS repos are not supported for delegation yet"
        case .submodule(let path, let problem): return problem.describe(path)
        case .unbornHead: return "this worktree has no commits yet; commit once before delegating"
        case .treeMismatch(let expected, let actual):
            return "the host's checkout has tree \(actual.prefix(12)), not the snapshot's \(expected.prefix(12)); nothing ran"
        case .bundleLacksSnapshot(let commit): return "the sync bundle does not contain snapshot \(commit.prefix(12))"
        case .invalidName(let name): return "invalid workspace name \"\(name)\""
        case .artifactTracked(let glob, let path):
            return "fetch glob \"\(glob)\" matches tracked file \(path); tracked files come back through `flightdeck diff`/`apply`"
        case .noCheckout: return "this worktree has never been synced to the host; use `flightdeck run` first"
        case .runActive: return "a run or service is still using this workspace; stop it first"
        case .resultExpired: return "the run's result is gone from the host (fetched already, or older than 24h)"
        case .unsafePath(let path): return "the host's result writes an unsafe path \"\(path)\"; nothing was applied"
        case .gitTooOld(let version): return "git \(version) is too old; delegation needs git 2.40 or later"
        }
    }
}

/// Why a submodule cannot be synced. The first three are the controller's refusals, raised
/// while snapshotting and never sent by a host; `fetchFailed` and `missingCommit` are the
/// host's, sent as `submodule_fetch_failed`. Each description names the path and the next step,
/// because the reader is usually an agent that can act only on what the line tells it.
public enum SubmoduleProblem: Equatable, Sendable {
    /// Uncommitted or untracked changes inside it: only the pinned commit travels, so the host
    /// would run against something other than what the user is looking at.
    case dirty
    /// Pinned to a commit no remote-tracking branch or tag contains: a local commit the host
    /// could never fetch.
    case unpushed(commit: String)
    /// A gitlink with no URL in `.gitmodules` or the local config: a nested repository that
    /// was never registered as a submodule.
    case noURL
    /// The host could not fetch from the URL at all.
    case fetchFailed(url: String, detail: String)
    /// The host fetched from the URL, and the pinned commit was not there.
    case missingCommit(url: String, commit: String)
    /// A fetched submodule commit records a nested gitlink whose path has an empty, `.`,
    /// `..` or `.git` component: placing it would write outside the submodule or into git's
    /// own files. The host's refusal; nothing is placed.
    case unsafePath

    public var code: String {
        switch self {
        case .dirty: return "submodule_dirty"
        case .unpushed: return "submodule_unpushed"
        case .noURL: return "submodule_no_url"
        case .fetchFailed, .missingCommit: return "submodule_fetch_failed"
        case .unsafePath: return "submodule_unsafe_path"
        }
    }

    func describe(_ path: String) -> String {
        switch self {
        case .dirty:
            return "submodule \(path) has uncommitted changes; commit them inside \(path) and in the superproject, or discard them, then rerun"
        case .unpushed(let commit):
            return "submodule \(path) is at \(commit.prefix(12)), which no branch or tag of its remote contains; push it (git -C \(path) push), or fetch if it is already pushed, then rerun"
        case .noURL:
            return "\(path) is a nested git repository with no URL in .gitmodules; add it with git submodule add <url> \(path), or ignore it, then rerun"
        // Redacted: these quote a URL from the wire and git's own words about it, and either
        // may carry a token (`SubmoduleURL.redacted`).
        case .fetchFailed(let url, let detail):
            let detail = SubmoduleURL.redacted(detail.trimmingCharacters(in: .whitespacesAndNewlines))
            return "couldn't fetch submodule \(path) from \(SubmoduleURL.redacted(url)): \(detail); make that URL reachable from the host, then rerun"
        case .unsafePath:
            return "refused submodule path \(path): it leaves its parent or enters .git; nothing was placed there. Fix the commit that records it, then rerun"
        case .missingCommit(let url, let commit):
            return "submodule \(path)'s commit \(commit.prefix(12)) is not on \(SubmoduleURL.redacted(url)); push it, then rerun"
        }
    }
}

/// Runs `git` with an explicit environment, a timeout, and captured stdout and stderr.
public struct GitRunner: Sendable {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
        /// stdout as UTF-8 with surrounding whitespace trimmed.
        public var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private let executable: URL?
    private let environment: [String: String]
    public let timeout: TimeInterval

    /// `isolated` is for the host: its git ignores the host user's system and global config, so
    /// a `core.autocrlf`, a global excludes file or an `alias` on the build box cannot change
    /// what a checkout contains or what a result commit captures. The controller is *not*
    /// isolated: its global excludes file is part of what the user means by "ignored".
    ///
    /// Both sides disable hooks (a user's `reference-transaction` or `post-checkout` hook
    /// must not fire on Flight Deck's internal refs and checkouts) and pin a fixed identity,
    /// so `commit-tree` works on a host that has never configured `user.name`. Both turn
    /// signing off: these commits are plumbing nobody verifies, and a user's `commit.gpgSign`
    /// with a key gpg cannot use, or a pinentry nobody can answer from hostd, would fail every
    /// snapshot and result. `commit-tree` ignores the setting since git 2.15; this holds for
    /// any commit or tag path, and for a repo-local setting the isolated host would still read.
    public init(isolated: Bool = false, timeout: TimeInterval = 600) {
        self.executable = GitRunner.locate()
        self.timeout = timeout
        let inherited = ProcessInfo.processInfo.environment
        // Inherited GIT_* would silently redirect us: an agent that runs `flightdeck run` from a
        // git hook has GIT_DIR and GIT_INDEX_FILE set to the *user's* repo and index.
        var env = inherited.filter { !$0.key.hasPrefix("GIT_") }
        env["PATH"] = inherited["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        env["LC_ALL"] = "C"   // stable messages and sort order for the parsers below
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Read-only commands must not refresh the user's real index behind their back.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_AUTHOR_NAME"] = "Flight Deck"; env["GIT_AUTHOR_EMAIL"] = "flightdeck@localhost"
        env["GIT_COMMITTER_NAME"] = "Flight Deck"; env["GIT_COMMITTER_EMAIL"] = "flightdeck@localhost"
        var config = [("core.hooksPath", "/dev/null"), ("commit.gpgSign", "false"), ("tag.gpgSign", "false")]
        if isolated {
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        } else {
            // Our fetches and ref updates in the user's repo must not kick off a background gc.
            config += [("gc.auto", "0"), ("maintenance.auto", "false")]
        }
        env["GIT_CONFIG_COUNT"] = String(config.count)
        for (i, (key, value)) in config.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = key
            env["GIT_CONFIG_VALUE_\(i)"] = value
        }
        self.environment = env
    }

    /// The first `git` on `PATH`, then the usual install locations: a launchd-started hostd
    /// has a minimal `PATH` that may not include Homebrew.
    private static func locate() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        return dirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("git") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The most paths one command line carries. Long paths reach the kernel's ARG_MAX, and an
    /// over-long command line fails the whole call; a path list longer than this is split or
    /// sent on stdin. (It was also NSTask's limit of 4,096 arguments, an uncatchable abort,
    /// while git ran through `Process`; the controller's other `Process` callers still have it.)
    static let argumentBatch = 500

    /// For the calls that move a whole repository: a first `bundle create`, its `fetch`, and a
    /// big `checkout` can legitimately take far longer than the default.
    public static let longTimeout: TimeInterval = 3600

    /// Runs `git args` in `dir`. Throws `GitError.failed` for a status outside `accept`, and
    /// `SyncError.gitTooOld` (once per executable, then cached) for git older than 2.40.
    ///
    /// `stall` is a progress watchdog: git is killed (its whole group) and `GitError.stalled`
    /// thrown once stdout and stderr have both been silent that long. Only meaningful for a
    /// command that reports progress (a `fetch --progress`); `timeout` still caps the whole.
    @discardableResult
    public func run(_ args: [String], in dir: URL? = nil, env extra: [String: String] = [:],
                    input: Data? = nil, accept: Set<Int32> = [0], timeout: TimeInterval? = nil,
                    stall: TimeInterval? = nil) throws -> Output {
        guard let executable else { throw GitError.notFound }
        if GitCancellation.current?.isCancelled == true { throw CancellationError() }
        try Self.requireSupported(executable, environment: environment)
        return try execute(executable, args, in: dir, env: environment.merging(extra) { $1 }, input: input,
                           accept: accept, timeout: timeout ?? self.timeout, stall: stall)
    }

    private func execute(_ executable: URL, _ args: [String], in dir: URL?, env: [String: String], input: Data?,
                         accept: Set<Int32>, timeout: TimeInterval, stall: TimeInterval? = nil) throws -> Output {
        // posix_spawn, not `Process`: git leads a process group of its own on every platform
        // (so a cancel or a timeout reaches ssh and remote helpers with it), starts with no
        // blocked signals, and inherits only its three pipes (see `Spawner.spawnProcess`).
        let out = try Spawner.makePipe(), err = try Spawner.makePipe()
        let inPipe = try input.map { _ in try Spawner.makePipe() }
        // Above 2, like the pipes: a hostd started with stdin closed gets fd 0 back here, and
        // `dup2(0, 0)` would leave it close-on-exec, so git would start with no stdin at all.
        let devNull = inPipe == nil ? try Spawner.cloexecAboveStdio(open("/dev/null", O_RDONLY | O_CLOEXEC)) : -1
        let pid: pid_t
        do {
            pid = try Spawner.spawnProcess(executable.path, [executable.path] + args, env: env, cwd: dir?.path,
                                           stdin: inPipe?.read ?? devNull, stdout: out.write, stderr: err.write)
        } catch {
            for fd in [out.read, out.write, err.read, err.write, inPipe?.read ?? -1, inPipe?.write ?? -1, devNull] where fd >= 0 {
                close(fd)
            }
            throw error
        }
        // The parent's copies of the child's ends: kept open, a pipe never reaches EOF.
        for fd in [out.write, err.write, inPipe?.read ?? -1, devNull] where fd >= 0 { close(fd) }
        let cancel = GitCancellation.current
        if let cancel, !cancel.started(pid) { GitCancellation.kill(pid) }
        defer { cancel?.ended(pid) }

        let exited = DispatchSemaphore(value: 0)
        let box = Box()
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            box.lock.withLock { box.status = status }
            exited.signal()
        }

        // Both pipes drain on their own threads: a git that fills stderr while we block on
        // stdout (or the reverse) would otherwise deadlock until the timeout. Closing from the
        // reader, at EOF, also covers the timeout path: a grandchild that outlives a killed git
        // holds the write end, and the read end must stay open until it lets go, then close.
        // Read in chunks, not to EOF in one call, so the watchdog below can see when the last
        // byte arrived.
        let drained = DispatchGroup()
        box.lastOutput = Date()
        for (fd, isOut) in [(out.read, true), (err.read, false)] {
            DispatchQueue.global().async(group: drained) {
                defer { close(fd) }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return }
                    box.lock.withLock {
                        if isOut { box.out.append(contentsOf: chunk[..<n]) } else { box.err.append(contentsOf: chunk[..<n]) }
                        box.lastOutput = Date()
                    }
                }
            }
        }
        if let inPipe, let input {
            DispatchQueue.global().async {
                Self.writeWithoutSIGPIPE(input, to: FileHandle(fileDescriptor: inPipe.write, closeOnDealloc: false))
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while exited.wait(timeout: .now() + min(1, max(0, deadline.timeIntervalSinceNow))) == .timedOut {
            if let stall, Date().timeIntervalSince(box.lock.withLock({ box.lastOutput })) >= stall {
                // Killed outright: a stalled transfer has nothing worth a graceful exit.
                GitCancellation.kill(pid)
                _ = exited.wait(timeout: .now() + 2)
                throw GitError.stalled(args: args, seconds: stall)
            }
            guard Date() >= deadline else { continue }
            // The group: git's ssh or helper would otherwise keep the transfer going.
            _ = Foundation.kill(-pid, SIGTERM)
            if exited.wait(timeout: .now() + 2) == .timedOut {
                GitCancellation.kill(pid)
                _ = exited.wait(timeout: .now() + 2)
            }
            throw GitError.timedOut(args: args, seconds: timeout)
        }
        // A grandchild (a credential helper, a filter) still holding a pipe must not pin us.
        _ = drained.wait(timeout: .now() + 5)
        let (stdout, stderr, raw) = box.lock.withLock { (box.out, box.err, box.status) }
        // WIFEXITED / WTERMSIG by hand (Swift imports neither); a signal reads as 128 + n,
        // as `Process` reported it.
        let signal = raw & 0x7f
        let status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
        let result = Output(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
        if cancel?.isCancelled == true, !accept.contains(status) { throw CancellationError() }
        guard accept.contains(status) else {
            throw GitError.failed(args: args, status: status, stderr: result.stderr)
        }
        return result
    }

    /// Writes `data` and closes `handle` without SIGPIPE. git can exit without reading all of
    /// its stdin, and the write then raises SIGPIPE, whose default action kills the whole
    /// process: in the hostd, every run and service on the host. Ignoring it process-wide
    /// instead would be inherited across exec by everything the process later spawns, so
    /// `producer | head` in a delegated run would spin on EPIPE. So the signal is suppressed
    /// for this one write, and the write fails with EPIPE (dropped: git's exit status is what
    /// matters).
    ///
    /// macOS raises it process-wide, so masking one thread would only move it to another;
    /// `F_SETNOSIGPIPE` turns it off for this descriptor. Linux raises it at the writing
    /// thread, so it is blocked there and the pending signal consumed before the mask returns.
    private static func writeWithoutSIGPIPE(_ data: Data, to handle: FileHandle) {
        #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? handle.write(contentsOf: data)
        try? handle.close()
        #else
        var pipeOnly = sigset_t()
        sigemptyset(&pipeOnly)
        sigaddset(&pipeOnly, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeOnly, &previous)
        try? handle.write(contentsOf: data)
        try? handle.close()
        var pending = sigset_t()
        sigpending(&pending)
        if sigismember(&pending, SIGPIPE) == 1 {
            var caught: Int32 = 0
            sigwait(&pipeOnly, &caught)
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        #endif
    }

    private static let versionLock = NSLock()
    /// Executables whose version parsed and was new enough. Only a *parsed* verdict is
    /// cached: one failed `--version` (a transient fork failure, a wrapper's hiccup) must not
    /// pin "too old" on the executable for the rest of the process's life.
    nonisolated(unsafe) private static var supported: Set<String> = []

    /// Checks `git --version` once per executable. `merge-tree --write-tree --merge-base`
    /// (apply) needs 2.40; an older git would otherwise fail deep inside an apply with a usage
    /// error that names neither the cause nor the fix. An unparseable answer refuses nothing:
    /// the real command runs and fails, or not, on its own terms, and the next call asks again.
    private static func requireSupported(_ executable: URL, environment: [String: String]) throws {
        if versionLock.withLock({ supported.contains(executable.path) }) { return }
        let probe = GitRunner(isolated: true)
        let text = (try? probe.execute(executable, ["--version"], in: nil, env: environment, input: nil,
                                       accept: [0], timeout: 30).text) ?? ""
        guard let version = parsedVersion(text) else { return }
        guard isSupported(versionOutput: text) else { throw SyncError.gitTooOld(version) }
        versionLock.withLock { _ = supported.insert(executable.path) }
    }

    /// The `X.Y.Z` of `git version X.Y.Z…`, or nil when the output is not that.
    private static func parsedVersion(_ output: String) -> String? {
        let words = output.split(separator: " ")
        guard words.count >= 3, words[0] == "git", words[1] == "version", words[2].first?.isNumber == true else { return nil }
        return String(words[2])
    }

    /// True for `git version X.Y…` with X.Y ≥ 2.40.
    static func isSupported(versionOutput: String) -> Bool {
        let words = versionOutput.split(separator: " ")
        guard words.count >= 3, words[0] == "git", words[1] == "version" else { return false }
        let parts = words[2].split(separator: ".").prefix(2).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard parts.count == 2 else { return false }
        return parts[0] > 2 || (parts[0] == 2 && parts[1] >= 40)
    }

    /// `run(...).text`: trimmed stdout.
    public func text(_ args: [String], in dir: URL? = nil, env: [String: String] = [:], input: Data? = nil,
                     timeout: TimeInterval? = nil) throws -> String {
        try run(args, in: dir, env: env, input: input, timeout: timeout).text
    }

    /// NUL-separated stdout (`-z` output) split into fields, dropping the trailing empty one.
    public func fields(_ args: [String], in dir: URL? = nil, env: [String: String] = [:], input: Data? = nil) throws -> [String] {
        let out = try run(args, in: dir, env: env, input: input).stdout
        return out.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Runs blocking `work` on a global queue and resumes the caller with its result. The sync
    /// API is async (C0 amendment A1) because git can take minutes; running it inline would pin
    /// a cooperative-pool thread, and a handful of concurrent syncs would starve every other
    /// task in the process, including the transport that is feeding them bytes.
    ///
    /// Cancelling the calling task kills the git `work` is running (its whole process group,
    /// so a `git fetch`'s ssh or remote helper goes too), and every later git call in `work`
    /// throws `CancellationError`. Before, a cancel waited for git: a run cancelled while its
    /// checkout fetched a submodule from a hung remote held its slot until git's timeout.
    static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let cancel = GitCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global().async {
                    let previous = GitCancellation.current
                    GitCancellation.current = cancel
                    defer { GitCancellation.current = previous }
                    cont.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var out = Data()
        var err = Data()
        var status: Int32 = 0
        var lastOutput = Date()
    }
}

/// The cancel `GitRunner.offload` hands the git calls of one blocking body, through a
/// thread-local: the body runs synchronously on one dispatch thread, and threading a token
/// through every git call in Workspace and Submodules would touch them all for one concern.
final class GitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running: Set<pid_t> = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let pids: Set<pid_t> = lock.withLock {
            cancelled = true
            return running
        }
        pids.forEach(Self.kill)
    }

    /// Records a git just started; false when the body was already cancelled (kill it).
    func started(_ pid: pid_t) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            running.insert(pid)
            return true
        }
    }

    func ended(_ pid: pid_t) { _ = lock.withLock { running.remove(pid) } }

    /// SIGKILL to git's process group (`Spawner.spawnProcess` makes git its leader) and to
    /// git itself. Not TERM: git now starts with no blocked signals, but its ssh or helper may
    /// block or catch TERM, and a cancel must end the transfer now. What a killed fetch leaves
    /// behind (lock files) is cleared by the next fetch into the same cache.
    static func kill(_ pid: pid_t) {
        _ = Foundation.kill(-pid, SIGKILL)
        _ = Foundation.kill(pid, SIGKILL)
    }

    private static let key = "dev.flightdeck.git-cancellation"

    static var current: GitCancellation? {
        get { Thread.current.threadDictionary[key] as? GitCancellation }
        set { Thread.current.threadDictionary[key] = newValue }
    }
}

/// Names that arrive over the wire become directory names and ref components on the host. One
/// containing `/` or `..` would write outside its workspace; one with ref-illegal characters
/// would fail later, mid-sync, with an opaque git error.
enum SyncName {
    static func validate(_ name: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+@")
        guard !name.isEmpty, name.count <= 255, name != ".", name != "..", !name.hasPrefix("."),
              !name.hasSuffix(".lock"), !name.contains(".."), name.allSatisfy(allowed.contains)
        else { throw SyncError.invalidName(name) }
        return name
    }

    /// The worktree's basename, which becomes the host checkout's innermost directory. Unlike
    /// the other names it never becomes a ref, so spaces and dots are fine; only a path
    /// separator or a dot-only name could escape the slot.
    static func directory(_ name: String) throws -> String {
        guard !name.isEmpty, name.count <= 255, name != ".", name != "..", !name.contains("/"), !name.contains("\0")
        else { throw SyncError.invalidName(name) }
        return name
    }

    /// A git object id: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.
    static func objectID(_ id: String) throws -> String {
        guard id.count == 40 || id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw SyncError.invalidName(id)
        }
        return id
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
