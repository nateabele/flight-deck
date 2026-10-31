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
    /// A link, FIFO or device in the output folder, by relative path. Copying it out would let
    /// a generator hand the caller a pointer to any file on the Mac.
    case outputNotRegularFile(String)

    public var description: String {
        switch self {
        case .noGenerator: return "the provider has no generator"
        case .networkNotAllowed: return "the generator asks for network access, which providers may not have"
        case .notTrusted(let state): return "the provider may not run code (\(state))"
        case .sandboxUnavailable(let path): return "\(path) is missing, and a generator never runs unsandboxed"
        case .providerChanged(let expected, let actual):
            return "the provider folder changed since it was approved (expected \(expected), found \(actual))"
        case .snapshotFailed(let why): return "could not make a private copy of the provider: \(why)"
        case .outputNotRegularFile(let path): return "the generator's output \(path) is not a regular file"
        }
    }
}

public enum ProviderSandboxResult: Equatable, Sendable {
    /// `outputs` lists the files delivered to the output directory, by relative path. It is
    /// empty unless `code` is 0: a failed generator's partial output is not delivered.
    case exited(code: Int32, stdout: Data, stderr: String, outputs: [String])
    /// The generator outlived its timeout. Its whole process group has been killed.
    case timedOut
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

    public static let environmentPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Read at run time with `-D`, not spliced into the text, so no path can break out of a
    /// string literal and add a rule. `(deny file-write*)` then a narrower allow: in SBPL the
    /// later matching rule wins. `/dev/null` is allowed because `2>/dev/null` is in every script.
    public static let profile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write*
          (subpath (param "OUTPUT_DIR"))
          (subpath (param "TEMP_DIR"))
          (literal "/dev/null"))
        """

    public init(sandboxExecPath: String = "/usr/bin/sandbox-exec", runner: any CommandRunner = SystemCommandRunner(),
                snapshotRoot: URL = FileManager.default.temporaryDirectory, killGrace: TimeInterval = 2) {
        self.sandboxExecPath = sandboxExecPath
        self.runner = runner
        self.snapshotRoot = snapshotRoot
        self.killGrace = killGrace
    }

    /// Runs `provider`'s generator once. On exit 0 the generator's output folder is copied into
    /// `outputDirectory`. `{out}` in the arguments is the generator's output folder; each
    /// `placeholders` key `k` replaces `{k}`. `onSpawn` gets the pid, which is also the process
    /// group id.
    public func run(_ provider: ResolvedProvider, outputDirectory: URL, placeholders: [String: String] = [:],
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

        let profileURL = run.root.appendingPathComponent("profile.sb")
        try Data(Self.profile.utf8).write(to: profileURL)
        // Real paths: `$TMPDIR` is under /var, a link to /private/var, and the sandbox matches
        // `subpath` against the resolved path, so the unresolved one would allow nothing.
        let outPath = try Self.realPath(run.output)
        let tempPath = try Self.realPath(run.temp)
        let cwd = run.snapshot

        var values = placeholders
        values["out"] = outPath
        let program = Self.program(generator.command[0], in: cwd)
        let args = generator.command.dropFirst().map { Self.substitute($0, values) }
        let arguments = ["-D", "OUTPUT_DIR=\(outPath)", "-D", "TEMP_DIR=\(tempPath)",
                         "-f", profileURL.path, program] + args
        // Nothing inherited: the app's environment holds tokens and socket paths a generator
        // has no business reading.
        let environment = ["PATH": Self.environmentPath, "HOME": tempPath, "TMPDIR": tempPath]

        let outcome = try await runOnClock(arguments: arguments, cwd: cwd, environment: environment,
                                           timeout: TimeInterval(generator.timeout.seconds), onSpawn: onSpawn)
        guard case .exited(let code, let stdout, let stderr, _) = outcome else { return outcome }
        guard code == 0 else { return outcome }
        let outputs = try deliver(from: run.output, to: outputDirectory)
        return .exited(code: code, stdout: stdout, stderr: stderr, outputs: outputs)
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

    /// The parser stores `./bin/render` as `bin/render` and `./gen.sh` as `gen.sh`, which
    /// leaves a bare name ambiguous. A name that is a file in the copy is the provider's own;
    /// anything else is left for `sandbox-exec`'s PATH lookup.
    static func program(_ name: String, in snapshot: URL) -> String {
        if name.hasPrefix("/") { return name }
        let candidate = snapshot.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        if name.contains("/") || (FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                                  && !isDirectory.boolValue) {
            return candidate.path
        }
        return name
    }

    static func substitute(_ arg: String, _ values: [String: String]) -> String {
        values.reduce(arg) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
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
    /// that traps SIGTERM still dies, and so does every child in its group.
    private func runOnClock(arguments: [String], cwd: URL, environment: [String: String], timeout: TimeInterval,
                            onSpawn: (@Sendable (Int32) -> Void)?) async throws -> ProviderSandboxResult {
        let group = GroupID()
        let expired = Flag()
        let runner = self.runner, executable = sandboxExecPath, grace = killGrace
        let work = Task {
            try await runner.run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                                 processGroup: true, onSpawn: { pid in group.set(pid); onSpawn?(pid) })
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            expired.set()
            if let pgid = group.value { killpg(pgid, SIGTERM) }
            work.cancel()
            try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            group.killIfAlive()
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
        // The leader is gone, but a child that closed its streams can outlive it: sweep the
        // group so nothing the generator started keeps running unowned.
        group.killIfAlive()

        if expired.value { return .timedOut }
        let done = try result.get()
        return .exited(code: done.exitCode, stdout: done.stdout, stderr: done.stderr, outputs: [])
    }

    // MARK: - Delivery

    /// Checks every entry before copying any, so a refused output delivers nothing.
    private func deliver(from source: URL, to destination: URL) throws -> [String] {
        var files: [String] = []
        var directories: [String] = []
        try Self.walk(source, prefix: "", files: &files, directories: &directories)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for dir in directories {
            try fm.createDirectory(at: destination.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in files {
            let target = destination.appendingPathComponent(file)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source.appendingPathComponent(file), to: target)
        }
        return files.sorted()
    }

    private static func walk(_ dir: URL, prefix: String, files: inout [String], directories: inout [String]) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        for url in entries {
            let relative = prefix.isEmpty ? url.lastPathComponent : "\(prefix)/\(url.lastPathComponent)"
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { throw ProviderSandboxError.outputNotRegularFile(relative) }
            if values?.isDirectory == true {
                directories.append(relative)
                try walk(url, prefix: relative, files: &files, directories: &directories)
            } else if values?.isRegularFile == true {
                files.append(relative)
            } else {
                throw ProviderSandboxError.outputNotRegularFile(relative)
            }
        }
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
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.lock(); isSet = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
}
