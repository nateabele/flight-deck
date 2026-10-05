import Foundation

// The sync engine's only door to git (spec §4): the `git` CLI through `Process`, never
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

    public var description: String {
        switch self {
        case .notFound: return "git is not installed"
        case .failed(let args, let status, let stderr):
            return "git \(args.joined(separator: " ")) exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut(let args, let seconds):
            return "git \(args.joined(separator: " ")) timed out after \(Int(seconds))s"
        }
    }
}

/// The sync engine's own refusals. `description` is the text after `flightdeck: ` on the CLI;
/// `code` is the host error code the router replies with (C0 amendment A5).
public enum SyncError: Error, Equatable, CustomStringConvertible {
    case lfsUnsupported
    case submodulesUnsupported
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

    public var code: String {
        switch self {
        case .lfsUnsupported: return "lfs_unsupported"
        case .submodulesUnsupported: return "submodules_unsupported"
        case .treeMismatch: return "tree_mismatch"
        case .noCheckout: return "no_checkout"
        case .runActive: return "run_active"
        case .unbornHead, .bundleLacksSnapshot, .invalidName, .artifactTracked: return "unsupported"
        }
    }

    public var description: String {
        switch self {
        case .lfsUnsupported: return "LFS repos are not supported for delegation yet"
        case .submodulesUnsupported: return "repos with submodules are not supported for delegation yet"
        case .unbornHead: return "this worktree has no commits yet; commit once before delegating"
        case .treeMismatch(let expected, let actual):
            return "the host's checkout has tree \(actual.prefix(12)), not the snapshot's \(expected.prefix(12)); nothing ran"
        case .bundleLacksSnapshot(let commit): return "the sync bundle does not contain snapshot \(commit.prefix(12))"
        case .invalidName(let name): return "invalid workspace name \"\(name)\""
        case .artifactTracked(let glob, let path):
            return "fetch glob \"\(glob)\" matches tracked file \(path); tracked files come back through `flightdeck diff`/`apply`"
        case .noCheckout: return "this worktree has never been synced to the host; use `flightdeck run` first"
        case .runActive: return "a run or service is still using this workspace; stop it first"
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
    /// so `commit-tree` works on a host that has never configured `user.name`.
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
        var config = [("core.hooksPath", "/dev/null")]
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

    /// Runs `git args` in `dir`. Throws `GitError.failed` for a status outside `accept`.
    @discardableResult
    public func run(_ args: [String], in dir: URL? = nil, env extra: [String: String] = [:],
                    input: Data? = nil, accept: Set<Int32> = [0]) throws -> Output {
        guard let executable else { throw GitError.notFound }
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        p.environment = environment.merging(extra) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()

        // Both pipes drain on their own threads: a git that fills stderr while we block on
        // stdout (or the reverse) would otherwise deadlock until the timeout.
        let box = Box()
        let drained = DispatchGroup()
        for (handle, isOut) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            DispatchQueue.global().async(group: drained) {
                let data = handle.readDataToEndOfFile()
                box.lock.withLock { if isOut { box.out = data } else { box.err = data } }
            }
        }
        if let inPipe, let input {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            throw GitError.timedOut(args: args, seconds: timeout)
        }
        // A grandchild (a credential helper, a filter) still holding a pipe must not pin us.
        // Once drained, the read ends are closed here: Foundation never closes them, and two
        // leaked descriptors per call took a test process past 800 open fds, where Linux
        // corelibs' `/proc/self/fd` walk in `Process.run` segfaults. If the drain timed out a
        // reader still owns its handle, so that rare call leaks rather than closing under it.
        if drained.wait(timeout: .now() + 5) == .success {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        let (stdout, stderr) = box.lock.withLock { (box.out, box.err) }
        let status = p.terminationReason == .exit ? p.terminationStatus : 128 + p.terminationStatus
        let result = Output(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
        guard accept.contains(status) else {
            throw GitError.failed(args: args, status: status, stderr: result.stderr)
        }
        return result
    }

    /// `run(...).text`: trimmed stdout.
    public func text(_ args: [String], in dir: URL? = nil, env: [String: String] = [:], input: Data? = nil) throws -> String {
        try run(args, in: dir, env: env, input: input).text
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
    static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var out = Data()
        var err = Data()
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
