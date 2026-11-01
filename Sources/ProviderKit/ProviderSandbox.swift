import Darwin
import Foundation
import HostKit
import IntakeKit

/// Why a generator did not run, or why its output was not delivered. Every case is a refusal
/// made before or after the process, never a generator's own failure (that is an exit code).
public enum ProviderSandboxError: Error, Equatable, CustomStringConvertible {
    /// A data-only provider: there is nothing to run.
    case noGenerator
    /// Contract 1 has no networked generators, so `network = true` is refused, not downgraded.
    case networkNotAllowed
    /// Only bundled, user and approved repo providers may run code.
    case notTrusted(ProviderTrustState)
    /// `sandbox-exec` is not at the injected path. A generator never runs unsandboxed.
    case sandboxUnavailable(String)
    /// The private copy does not hash to the digest that was approved (or, for bundled and user
    /// providers, to the folder as it stood when the run began).
    case providerChanged(expected: String, actual: String)
    case snapshotFailed(String)
    /// `command[0]` names a file in the provider folder (`./gen.sh`) that is not there.
    case programMissing(String)
    /// A link, FIFO or device in the output folder, by relative path. Copying it out would let
    /// a generator hand the caller a pointer to any file on the Mac.
    case outputNotRegularFile(String)
    /// Something of the generator's process group outlived a SIGKILL; delivery, which reads its
    /// folder, does not start while anything of the run can still write to it.
    case generatorStillRunning

    public var description: String {
        switch self {
        case .noGenerator: return "the provider has no generator"
        case .networkNotAllowed: return "the generator asks for network access, which providers may not have"
        case .notTrusted(let state): return "the provider may not run code (\(state))"
        case .sandboxUnavailable(let path): return "\(path) is missing, and a generator never runs unsandboxed"
        case .providerChanged(let expected, let actual):
            return "the provider folder changed since it was approved (expected \(expected), found \(actual))"
        case .snapshotFailed(let why): return "could not make a private copy of the provider: \(why)"
        case .programMissing(let name): return "the generator \(name) is not in the provider folder"
        case .outputNotRegularFile(let path): return "the generator's output \(path) is not a regular file"
        case .generatorStillRunning: return "the generator's processes would not stop"
        }
    }
}

public enum ProviderSandboxResult: Equatable, Sendable {
    /// `outputs` lists the files delivered to the output directory, by relative path. It is
    /// empty unless `code` is 0: a failed generator's partial output is not delivered.
    case exited(code: Int32, stdout: Data, stderr: String, outputs: [String])
    /// The generator outlived its timeout. Its whole process group has been killed.
    case timedOut
    /// The generator was stopped for writing too much: `"stdout"`, `"out/"`, `"tmp/"` or
    /// `"file"` (one file past the per-file cap). Nothing is delivered.
    case outputTooLarge(String)
}

/// Runs a visual provider's generator (spec §9, ruling K-R3): from a private, re-checked copy of
/// the provider folder, under `sandbox-exec` with no network, writes only to its own output
/// and temp folders, a minimal environment, and a hard timeout.
public struct ProviderSandbox: Sendable {
    public let sandboxExecPath: String
    public let runner: any CommandRunner
    /// Where each run's private folder is made. `$TMPDIR` by default; tests pass their own.
    public let snapshotRoot: URL
    /// Seconds between SIGTERM and SIGKILL once the timeout expires.
    public let killGrace: TimeInterval
    public let limits: Limits
    /// Where Flight Deck warms the xcrun cache each run starts with a copy of.
    public let xcrunSeedFolder: URL
    /// Tests only: runs after the generator and every process holding its pipes are gone, and
    /// before delivery reads the output, standing in for a process that escaped both and
    /// rewrites the folder at the worst moment.
    var beforeDelivery: (@Sendable (URL) -> Void)?

    public struct Limits: Sendable, Equatable {
        /// Bytes of stdout kept in memory.
        public var stdout: Int
        /// Bytes on disk under `out/` (spec §9's 10 MB visual) and under `tmp/`.
        public var output: Int
        public var temp: Int
        /// The largest single file the generator may write anywhere (`ulimit -f`).
        public var file: Int

        public init(stdout: Int, output: Int, temp: Int, file: Int) {
            self.stdout = stdout
            self.output = output
            self.temp = temp
            self.file = file
        }

        public static let standard = Limits(stdout: 1 << 20, output: 10 << 20, temp: 256 << 20, file: 64 << 20)
    }

    /// Flight Deck's own xcrun cache: `~/Library/Caches/dev.flightdeck/xcrun-seed`, 0700.
    public static var defaultXcrunSeedFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? userHome.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("dev.flightdeck/xcrun-seed", isDirectory: true)
    }

    /// Runs the `ulimit` script. Bash, never `/bin/sh`: see `runOnClock`.
    static let launcher = "/bin/bash"

    /// The system's directories first, then Homebrew's (Apple silicon, then Intel), so
    /// `#!/usr/bin/env node` works without a provider shadowing a system tool.
    public static let environmentPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    /// Paths are read at run time with `-D`, not spliced into the text, so no path can break
    /// out of a string literal and add a rule. In SBPL the later matching rule wins, so each
    /// deny is followed by its narrower allow. `/dev/null` is writable because `2>/dev/null` is
    /// in every script.
    ///
    /// `(allow default)` alone left three ways out, all shown live by review:
    /// - `lsopen`: `open Probe.app` had LaunchServices launch an app OUTSIDE the sandbox, which
    ///   then wrote anywhere and reached the network;
    /// - `mach-lookup` and `appleevent-send`: any system service that acts for its caller (the
    ///   pasteboard server answered `pbpaste`);
    /// - reads of the home folder: `~/.ssh` and the login keychain, copyable into `out/`.
    /// Round two closed three more:
    /// - reads of the user's `/private/var/folders/<xx>/<yy>/` (its `T/` holds other provider
    ///   runs, its `C/` the user's caches) and of `/private/tmp` (other sessions' scratch files);
    /// - `signal`: a generator could `kill -TERM` any process of the same user, Flight Deck
    ///   included. Now only its own processes, so it can still stop its children.
    /// Round three: `/private/var/tmp` and `/Users/Shared`, world-writable scratch space like
    /// `/private/tmp`, where other sessions and apps leave files.
    /// All of that stays readable only where the run itself lives and where its input is: the
    /// allow comes after every read deny.
    public static let profile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write*
          (subpath (param "OUTPUT_DIR"))
          (subpath (param "TEMP_DIR"))
          (literal "/dev/null"))
        (deny file-read* (subpath (param "HOME_DIR")))
        (deny file-read* (subpath (param "USER_VAR_DIR")) (subpath "/private/tmp")
          (subpath "/private/var/tmp") (subpath "/Users/Shared"))
        (allow file-read*
          (subpath (param "RUN_ROOT"))
          (subpath (param "INPUT_DIR")))
        (deny lsopen)
        (deny appleevent-send)
        (deny mach-lookup)
        (deny signal)
        (allow signal (target same-sandbox))
        """

    public init(sandboxExecPath: String = "/usr/bin/sandbox-exec", runner: any CommandRunner = SystemCommandRunner(),
                snapshotRoot: URL = FileManager.default.temporaryDirectory, killGrace: TimeInterval = 2,
                limits: Limits = .standard, xcrunSeedFolder: URL = ProviderSandbox.defaultXcrunSeedFolder) {
        self.sandboxExecPath = sandboxExecPath
        self.runner = runner
        self.snapshotRoot = snapshotRoot
        self.killGrace = killGrace
        self.limits = limits
        self.xcrunSeedFolder = xcrunSeedFolder
    }

    /// Runs `provider`'s generator once. On exit 0 the generator's output folder is copied into
    /// `outputDirectory`. `{out}` in the arguments is the generator's output folder; each
    /// `placeholders` key `k` replaces `{k}`. `onSpawn` gets the pid, which is also the process
    /// group id.
    public func run(_ provider: ResolvedProvider, outputDirectory: URL, inputDirectory: URL? = nil,
                    placeholders: [String: String] = [:],
                    onSpawn: (@Sendable (Int32) -> Void)? = nil) async throws -> ProviderSandboxResult {
        // Every refusal that needs no file system comes first, so a refused run touches nothing.
        guard let generator = provider.manifest?.generator, !generator.command.isEmpty else {
            throw ProviderSandboxError.noGenerator
        }
        guard !generator.network else { throw ProviderSandboxError.networkNotAllowed }
        switch provider.trust {
        case .bundled, .user, .repoApproved: break
        case .repoDataOnly, .repoNeedsApproval, .unusable: throw ProviderSandboxError.notTrusted(provider.trust)
        }
        guard FileManager.default.isExecutableFile(atPath: sandboxExecPath) else {
            throw ProviderSandboxError.sandboxUnavailable(sandboxExecPath)
        }

        let run = try RunFolder(root: snapshotRoot)
        defer { run.remove() }
        try snapshot(provider, into: run)
        await seedXcrunCache(into: run.temp)

        let profileURL = run.root.appendingPathComponent("profile.sb")
        // Real paths: `$TMPDIR` is under /var, a link to /private/var, and the sandbox matches
        // `subpath` against the resolved path, so the unresolved one would allow nothing.
        let outPath = try Self.realPath(run.output)
        let tempPath = try Self.realPath(run.temp)
        let rootPath = try Self.realPath(run.root)
        let inputPath = try inputDirectory.map { try Self.realPath($0) } ?? rootPath
        let homePath = try Self.realPath(Self.userHome)
        let userVarPath = try Self.userVarFolder()
        let ancestors = Self.ancestors(of: [rootPath, inputPath])
        try Data(Self.profile(ancestorCount: ancestors.count).utf8).write(to: profileURL)
        let cwd = run.snapshot

        var values = placeholders
        values["out"] = outPath
        let program = try Self.program(generator, in: cwd)
        let args = generator.command.dropFirst().map { Self.substitute($0, values) }
        let arguments = ["-D", "OUTPUT_DIR=\(outPath)", "-D", "TEMP_DIR=\(tempPath)",
                         "-D", "HOME_DIR=\(homePath)", "-D", "RUN_ROOT=\(rootPath)", "-D", "INPUT_DIR=\(inputPath)",
                         "-D", "USER_VAR_DIR=\(userVarPath)"]
            + ancestors.enumerated().flatMap { ["-D", "ANCESTOR_\($0.offset)=\($0.element)"] }
            + ["-f", profileURL.path, program] + args
        // Nothing inherited: the app's environment holds tokens and socket paths a generator
        // has no business reading.
        // USER and LOGNAME because `getpwuid` needs a Mach service the profile denies: Python's
        // `getpass`, `whoami`-style scripts that read `$USER` and the like answer from them.
        // `id -un` does not read them and still prints the uid (501).
        let user = Self.userName
        let environment = ["PATH": Self.environmentPath, "HOME": tempPath, "TMPDIR": tempPath,
                           "USER": user, "LOGNAME": user]

        // Clamped, though the parser refuses more: a hand-built generator must not overflow the
        // nanosecond arithmetic either.
        let timeout = min(max(TimeInterval(generator.timeout.seconds), 0), TimeInterval(ProviderGenerator.maxTimeout.seconds))
        let outcome = try await runOnClock(arguments: arguments, cwd: cwd, environment: environment, timeout: timeout,
                                           output: run.output, temp: run.temp, onSpawn: onSpawn)
        guard case .exited(let code, let stdout, let stderr, _) = outcome, code == 0 else { return outcome }
        // Reached only once the group is confirmed gone and the runner has killed every pipe
        // holder. A process that escaped both can still rewrite `out/`, so delivery reads it
        // through descriptors that never follow a link.
        beforeDelivery?(run.output)
        let collected: Collected
        do { collected = try Self.collect(run.output, limit: limits.output) } catch is TooLarge {
            return .outputTooLarge("out/")
        }
        try Self.write(collected, to: outputDirectory)
        return .exited(code: code, stdout: stdout, stderr: stderr, outputs: collected.files.map(\.path).sorted())
    }

    /// Every `/usr/bin` developer shim (git, swift, clang, make) is xcrun, which caches its
    /// lookups in `$TMPDIR/xcrun_db`. Each run's TMPDIR is new, so every shim call was cold:
    /// `git --version` took about 1 s, 0.15 s warm (measured). The run starts with a COPY of
    /// Flight Deck's own cache (`XcrunSeed`), never the user's, which keys every HOME and temp
    /// folder xcrun ever ran under. A lookup the copy lacks is saved to the copy only, and the
    /// copy dies with the run, so no generator can write what a later one loads. Skipped when
    /// it would take more than a quarter of the temp cap, or is not a plain file.
    private func seedXcrunCache(into temp: URL) async {
        let seedFolder = xcrunSeedFolder
        let seed: URL? = await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning: XcrunSeed.shared.database(in: seedFolder)) }
        }
        guard let seed else { return }
        let source = open(seed.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { return }
        defer { close(source) }
        var info = stat()
        let budget = limits.temp / 4
        guard fstat(source, &info) == 0, Self.isType(info, S_IFREG), Int(info.st_size) <= budget,
              let data = try? Self.readAll(source, budget: budget) else { return }
        try? data.write(to: temp.appendingPathComponent("xcrun_db"))
    }

    // MARK: - The checked copy

    /// Copies the folder, then hashes the COPY. The copy is what runs, and nothing but this
    /// user can write to its 0700 parent, so a change to the original after this point cannot
    /// reach the run, and a change before it shows up as a digest mismatch.
    private func snapshot(_ provider: ResolvedProvider, into run: RunFolder) throws {
        let expected: String
        switch provider.trust {
        case .repoApproved:
            // The digest resolution matched against the trust store: the approved one.
            guard let digest = provider.digest else { throw ProviderSandboxError.notTrusted(provider.trust) }
            expected = digest
        default:
            // Bundled and user folders need no approval, but the copy must still be the folder
            // as it stood, not one caught half-way through an edit.
            do { expected = try ProviderTrust.digest(folder: provider.folder) } catch {
                throw ProviderSandboxError.snapshotFailed("\(error)")
            }
        }
        do {
            try FileManager.default.copyItem(at: provider.folder, to: run.snapshot)
        } catch {
            throw ProviderSandboxError.snapshotFailed(error.localizedDescription)
        }
        let actual: String
        do { actual = try ProviderTrust.digest(folder: run.snapshot) } catch {
            // A link or FIFO that appeared after approval: changed, and unhashable besides.
            throw ProviderSandboxError.snapshotFailed("\(error)")
        }
        guard actual == expected else { throw ProviderSandboxError.providerChanged(expected: expected, actual: actual) }
    }

    /// A provider-relative program runs from the copy and must be a file there: a missing one
    /// is refused, never turned into a PATH lookup of the same name. Anything else (absolute, or
    /// a bare name) is left for `sandbox-exec`'s own lookup on `environmentPath`.
    static func program(_ generator: ProviderGenerator, in snapshot: URL) throws -> String {
        let name = generator.command[0]
        guard generator.providerRelative else { return name }
        let candidate = snapshot.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ProviderSandboxError.programMissing(name)
        }
        return candidate.path
    }

    /// One pass, left to right: a substituted value is never scanned again, so a `{source}`
    /// whose value contains `{out}` stays literal. An unknown `{name}` is left as written.
    static func substitute(_ arg: String, _ values: [String: String]) -> String {
        var result = ""
        var rest = Substring(arg)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"), let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result.append("{")
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }

    /// The account's home from the user database, not `$HOME`, which the app's environment
    /// could have pointed anywhere.
    static var userHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The base profile, plus metadata reads of each folder above the run and the input:
    /// `mkdir -p` and `realpath` stat every ancestor, and those lie in denied areas (the temp
    /// folder, home). Only `file-read-metadata`, only those exact folders: their contents stay
    /// unlistable. Each path is a `-D` parameter, never text in the profile.
    static func profile(ancestorCount: Int) -> String {
        guard ancestorCount > 0 else { return profile }
        let literals = (0..<ancestorCount).map { "  (literal (param \"ANCESTOR_\($0)\"))" }.joined(separator: "\n")
        return profile + "\n(allow file-read-metadata\n" + literals + ")\n"
    }

    /// Every proper ancestor of `paths`, "/" included, without repeats, in a stable order.
    static func ancestors(of paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            var current = (path as NSString).deletingLastPathComponent
            while true {
                if seen.insert(current).inserted { result.append(current) }
                if current == "/" || current.isEmpty { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    static var userName: String {
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name { return String(cString: name) }
        return NSUserName()
    }

    /// The per-user `/private/var/folders/<xx>/<yy>`, the parent of `confstr`'s temp folder
    /// rather than of `$TMPDIR`, which the app's environment could have moved.
    static func userVarFolder() throws -> String {
        (try userTempFolder() as NSString).deletingLastPathComponent
    }

    /// `confstr`'s per-user temp folder (`.../T`), resolved.
    static func userTempFolder() throws -> String {
        var temp = FileManager.default.temporaryDirectory.path
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 { temp = String(cString: buffer) }
        }
        return try realPath(URL(fileURLWithPath: temp, isDirectory: true))
    }

    static func realPath(_ url: URL) throws -> String {
        // `realpath(3)`, not `resolvingSymlinksInPath`, which strips /private back off.
        guard let resolved = realpath(url.path, nil) else {
            throw ProviderSandboxError.snapshotFailed("cannot resolve \(url.path)")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - The clock

    /// `CommandRunner` has no timeout, so a watchdog races the run. On expiry it SIGTERMs the
    /// group and cancels the run, then SIGKILLs whatever is left after `killGrace`: a generator
    /// that traps SIGTERM still dies, and so does every child in its group. Beside it, the
    /// stdout counter and a disk watchdog SIGKILL the group the moment a cap is passed.
    private func runOnClock(arguments: [String], cwd: URL, environment: [String: String], timeout: TimeInterval,
                            output: URL, temp: URL,
                            onSpawn: (@Sendable (Int32) -> Void)?) async throws -> ProviderSandboxResult {
        let group = GroupID()
        let stop = StopReason()
        let stdoutBytes = ByteCount()
        let runner = self.runner, grace = killGrace, limits = self.limits
        // `ulimit -f` has the kernel stop any one file near the cap, which the disk watchdog
        // (every 250 ms) would only notice after the fact. Bash, named: its unit is 1024 bytes,
        // while dash and zsh count 512, and `/bin/sh` can be either (under dash a 1 MiB cap
        // stopped files at 512 KiB, measured). The limit is one block ABOVE the cap, so a file of
        // exactly the cap is written whole and anything larger is caught below by its size.
        // The shell runs our fixed script and is replaced by `env`, then sandbox-exec, so the
        // leader's pid is unchanged. `env -u`: bash exports PWD and SHLVL; `unset` cannot drop SHLVL.
        let blocks = limits.file / 1024 + 1
        let launch = ["-c", "ulimit -f \(blocks) || exit 126; exec /usr/bin/env -u PWD -u OLDPWD -u SHLVL \"$@\"",
                      "bash", sandboxExecPath] + arguments
        let work = Task {
            try await runner.run(executable: Self.launcher, arguments: launch, cwd: cwd, environment: environment,
                                 processGroup: true, onSpawn: { pid in group.set(pid); onSpawn?(pid) },
                                 onStdout: { chunk in
                                     if stdoutBytes.add(chunk.count) > limits.stdout, stop.set(.tooLarge("stdout")) {
                                         group.kill()
                                     }
                                 },
                                 // A process outside the group (no group kill reaches it) can
                                 // flood stdout through the runner's drain grace; one byte past
                                 // the cap is all the runner may keep.
                                 stdoutCapture: limits.stdout + 1)
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard stop.set(.timedOut) else { return }
            if let pgid = group.value { killpg(pgid, SIGTERM) }
            work.cancel()
            try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            group.killIfAlive()
        }
        let disk = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Self.diskUsage(output) > limits.output, stop.set(.tooLarge("out/")) { group.kill(); return }
                if Self.diskUsage(temp) > limits.temp, stop.set(.tooLarge("tmp/")) { group.kill(); return }
            }
        }
        let result: Result<CommandResult, Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            })
        } catch {
            result = .failure(error)
        }
        watchdog.cancel()
        disk.cancel()
        // The leader is gone, but a child that closed its streams can outlive it: sweep the
        // group, and wait for it to be empty, so nothing of the run is still writing when
        // delivery reads `out/`.
        group.killIfAlive()
        guard await group.waitUntilGone(seconds: 1) else { throw ProviderSandboxError.generatorStillRunning }

        switch stop.value {
        case .timedOut?: return .timedOut
        case .tooLarge(let what)?: return .outputTooLarge(what)
        case nil: break
        }
        let done = try result.get()
        // The counter above stops the group first; this catches a flood from outside it.
        if done.stdoutTruncated { return .outputTooLarge("stdout") }
        // SIGXFSZ, the per-file cap, as a signal death or as the shell's 128 + signal exit.
        if done.exitCode == 128 + SIGXFSZ { return .outputTooLarge("file") }
        // A program that ignores SIGXFSZ (Python, node) gets EFBIG and exits on its own terms;
        // a file past the cap is how the cap shows. Exactly the cap is allowed.
        if Self.largestFile(output) > limits.file || Self.largestFile(temp) > limits.file { return .outputTooLarge("file") }
        return .exited(code: done.exitCode, stdout: done.stdout, stderr: done.stderr, outputs: [])
    }

    /// Bytes allocated under `url`, from `lstat`, so a link is counted as itself and never
    /// followed out of the folder.
    static func diskUsage(_ url: URL) -> Int {
        guard let dir = opendir(url.path) else { return 0 }
        defer { closedir(dir) }
        var total = 0
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            let child = url.appendingPathComponent(name)
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            total += Int(info.st_blocks) * 512
            if Self.isType(info, S_IFDIR) { total += diskUsage(child) }
        }
        return total
    }

    /// The largest regular file under `url`, by `lstat`.
    static func largestFile(_ url: URL) -> Int {
        guard let dir = opendir(url.path) else { return 0 }
        defer { closedir(dir) }
        var largest = 0
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            let child = url.appendingPathComponent(name)
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            if isType(info, S_IFDIR) { largest = max(largest, largestFile(child)) }
            else if isType(info, S_IFREG) { largest = max(largest, Int(info.st_size)) }
        }
        return largest
    }

    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                String(cString: $0)
            }
        }
    }

    static func isType(_ info: stat, _ type: mode_t) -> Bool { (info.st_mode & S_IFMT) == type }

    // MARK: - Delivery

    struct Collected {
        var directories: [String] = []
        var files: [(path: String, data: Data)] = []
        var bytes = 0
    }

    struct TooLarge: Error {}

    /// Reads the whole output folder into memory before writing any of it, so a refused output
    /// delivers nothing. Every entry is opened with O_NOFOLLOW relative to its parent's
    /// descriptor, then checked with `fstat` on that descriptor: a link swapped in at any moment
    /// fails the open instead of being followed, and no path is ever looked up twice. Hard links
    /// are refused too: one is a regular file whose bytes belong to wherever it was linked from.
    static func collect(_ folder: URL, limit: Int) throws -> Collected {
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ProviderSandboxError.snapshotFailed("cannot open the output folder") }
        defer { close(root) }
        var collected = Collected()
        try collect(directory: root, prefix: "", limit: limit, into: &collected)
        return collected
    }

    private static func collect(directory: Int32, prefix: String, limit: Int, into collected: inout Collected) throws {
        for name in try names(in: directory) {
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            // O_NONBLOCK: a FIFO would otherwise block the open until someone writes to it.
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ProviderSandboxError.outputNotRegularFile(relative) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ProviderSandboxError.outputNotRegularFile(relative) }
            if isType(info, S_IFDIR) {
                collected.directories.append(relative)
                try collect(directory: fd, prefix: relative, limit: limit, into: &collected)
            } else if isType(info, S_IFREG), info.st_nlink == 1 {
                let data = try readAll(fd, budget: limit - collected.bytes)
                collected.bytes += data.count
                collected.files.append((relative, data))
            } else {
                throw ProviderSandboxError.outputNotRegularFile(relative)
            }
        }
    }

    private static func names(in directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw ProviderSandboxError.snapshotFailed("cannot list the output folder")
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// Reads to EOF, refusing past `budget`: the disk watchdog samples, so this is the check
    /// that holds at the moment of delivery.
    private static func readAll(_ fd: Int32, budget: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw ProviderSandboxError.snapshotFailed("cannot read the output") }
            if n == 0 { return data }
            data.append(contentsOf: buffer[0..<n])
            if data.count > budget { throw TooLarge() }
        }
    }

    /// Writes into the caller's folder the same way it read: each folder opened with
    /// O_NOFOLLOW from its parent, each file created O_EXCL | O_NOFOLLOW after removing any
    /// file of that name, so a link already in the destination is never written through.
    static func write(_ collected: Collected, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw ProviderSandboxError.snapshotFailed("cannot open \(destination.path)") }
        defer { close(root) }
        for dir in collected.directories { close(try openFolder(dir, under: root)) }
        for file in collected.files {
            let parentPath = (file.path as NSString).deletingLastPathComponent
            let name = (file.path as NSString).lastPathComponent
            let parent = parentPath.isEmpty ? dup(root) : try openFolder(parentPath, under: root)
            defer { close(parent) }
            if unlinkat(parent, name, 0) != 0, errno != ENOENT {
                throw ProviderSandboxError.snapshotFailed("cannot replace \(file.path) in the destination")
            }
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw ProviderSandboxError.snapshotFailed("cannot create \(file.path) in the destination") }
            defer { close(fd) }
            let ok = file.data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    offset += n
                }
                return true
            }
            guard ok else { throw ProviderSandboxError.snapshotFailed("cannot write \(file.path) in the destination") }
        }
    }

    private static func openFolder(_ path: String, under root: Int32) throws -> Int32 {
        var current = dup(root)
        for part in path.split(separator: "/") {
            let name = String(part)
            _ = mkdirat(current, name, 0o755)
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw ProviderSandboxError.snapshotFailed("\(path) is not a folder in the destination") }
            current = next
        }
        return current
    }
}

/// Flight Deck's own xcrun cache, warmed once per process per folder by `xcrun --find` of the
/// common shims, outside any sandbox and with no provider code: HOME, TMPDIR and `xcrun_db`
/// all point at the 0700 folder, so the db names nothing but it and the toolchain (measured:
/// 3.4 KB, one path, against the user's 2.1 MB and 13k paths).
private final class XcrunSeed: @unchecked Sendable {
    static let shared = XcrunSeed()
    static let tools = ["git", "swift", "python3", "clang", "make"]
    private let lock = NSLock()
    private var warmed: Set<String> = []

    /// The seed db, warmed first if this process has not yet. Nil when the folder is not a
    /// plain 0700 folder of this user's, or there is no developer directory to ask.
    func database(in folder: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard Self.prepare(folder) else { return nil }
        if warmed.insert(folder.path).inserted, Self.run("/usr/bin/xcode-select", ["-p"], folder) == 0 {
            // `xcode-select -p` first: with no developer directory `xcrun` offers to install one.
            for tool in Self.tools { _ = Self.run("/usr/bin/xcrun", ["--find", tool], folder) }
        }
        return folder.appendingPathComponent("xcrun_db")
    }

    private static func prepare(_ folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = mkdir(folder.path, 0o700)
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        return chmod(folder.path, 0o700) == 0
    }

    /// Exit status, or -1. Bounded: a wedged lookup is stopped after 30 s.
    private static func run(_ tool: String, _ arguments: [String], _ folder: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": ProviderSandbox.environmentPath, "HOME": folder.path, "TMPDIR": folder.path,
                               "xcrun_db": folder.appendingPathComponent("xcrun_db").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return -1 }
        if exited.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            guard exited.wait(timeout: .now() + 2) == .success else { return -1 }
        }
        return process.terminationStatus
    }
}

/// One run's private folder: `snapshot/` (the checked copy, and the working directory),
/// `out/` and `tmp/` (the only places the generator may write), and the profile.
private struct RunFolder {
    let root: URL
    var snapshot: URL { root.appendingPathComponent("snapshot", isDirectory: true) }
    var output: URL { root.appendingPathComponent("out", isDirectory: true) }
    var temp: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    init(root parent: URL) throws {
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ProviderSandboxError.snapshotFailed(error.localizedDescription)
        }
        // `mkdtemp`: the name is unpredictable and the folder is made 0700 in one step, so no
        // other user can pre-create it or slip a file in before the copy lands.
        var template = Array(parent.appendingPathComponent("fd-provider-XXXXXXXX").path.utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw ProviderSandboxError.snapshotFailed("mkdtemp failed: errno \(errno)")
        }
        root = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        } catch {
            remove()
            throw ProviderSandboxError.snapshotFailed(error.localizedDescription)
        }
    }

    /// A generator may leave a folder it made read-only, which `removeItem` cannot empty, so
    /// every folder is made writable first. The enumerator does not follow links.
    func remove() {
        let fm = FileManager.default
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { chmod(url.path, 0o700) }
            }
        }
        try? fm.removeItem(at: root)
    }
}

private final class GroupID: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    func set(_ value: Int32) { lock.lock(); pid = value; lock.unlock() }
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return pid }

    /// `killpg(_, 0)` first: a group id cannot be reused while the group has a member, so a
    /// group that answers is still ours. Once it is empty the probe finds nothing to kill.
    func killIfAlive() {
        guard let pgid = value, killpg(pgid, 0) == 0 else { return }
        killpg(pgid, SIGKILL)
    }

    /// While the leader may still be running, it holds the group id, so this cannot hit a
    /// stranger.
    func kill() {
        if let pgid = value { killpg(pgid, SIGKILL) }
    }

    /// False when the group still has a member after `seconds`.
    func waitUntilGone(seconds: Double) async -> Bool {
        guard let pgid = value else { return true }
        let deadline = Date().addingTimeInterval(seconds)
        while killpg(pgid, 0) == 0 {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}

/// Why the run was stopped, first cause only: a run killed for its stdout is not also
/// reported as timed out because the clock ran out while it was dying.
private final class StopReason: @unchecked Sendable {
    enum Reason { case timedOut, tooLarge(String) }
    private let lock = NSLock()
    private var reason: Reason?
    /// True when this call set it.
    func set(_ new: Reason) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reason == nil else { return false }
        reason = new
        return true
    }
    var value: Reason? { lock.lock(); defer { lock.unlock() }; return reason }
}

private final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; total += n; return total }
}
