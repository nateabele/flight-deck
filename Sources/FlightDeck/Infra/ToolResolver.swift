import CryptoKit
import Foundation
import IntakeKit

enum ToolSource: Equatable, Sendable { case path, managed }

/// A tool Flight Deck may run, by absolute path — never by bare name, so a managed copy never
/// shadows the user's own install for any other program (spec §4).
struct ResolvedTool: Equatable, Sendable {
    let tool: InfraTool
    let url: URL
    let version: SemVer
    let source: ToolSource
    /// Variables the caller merges into the environment whenever it runs this tool. For gcloud,
    /// `CLOUDSDK_PYTHON` naming a 3.10+ interpreter; empty for every other tool.
    var environment: [String: String] = [:]
}

enum ToolError: Error, Equatable {
    /// No compatible copy, and none provisioned; the string says what was found and why it was
    /// passed over ("found 1.6.0 at /opt/homebrew/bin/tofu, need >= 1.8.0, < 2").
    case missing(InfraTool, String)
    /// A managed download did not match its pinned SHA-256. A hard failure, never retried from
    /// another source: the pin is the only thing vouching for the bytes.
    case checksumMismatch(InfraTool)
    /// The download, the unpack, or the unpacked copy's own version check failed.
    case downloadFailed(InfraTool, String)
}

/// Finds `tofu`, `aws`, `gcloud` or `tailscale`: the first compatible copy on the search path,
/// else an already-unpacked managed copy under `managedRoot/<tool>/<version>/`, else — only when
/// asked to `provision` — a pinned download, verified against its checksum before anything is
/// unpacked.
///
/// Holds no mutable state, hence `@unchecked Sendable` only for the `CommandRunner` and
/// downloader existentials it stores.
final class ToolResolver: @unchecked Sendable {
    private let searchPath: [URL]
    private let managedRoot: URL
    private let runner: CommandRunner
    private let downloader: ToolDownloading
    private let pins: [InfraTool: ToolPin]
    /// How long one `--version` may take. A wedged CLI (gcloud on a broken Python, a tailscale
    /// whose daemon is hung) must cost seconds, not the whole setup flow.
    private let versionTimeout: TimeInterval
    /// The base environment every probe runs with, and where a user's own `CLOUDSDK_PYTHON` is
    /// read from. Injectable so a test's outcome never depends on the shell that launched it.
    private let environment: [String: String]
    /// Where a pin with `requiresSpaceFreePath` (the AWS pkg) is installed instead of
    /// `managedRoot`.
    private let spaceFreeRoot: URL

    init(searchPath: [URL], managedRoot: URL, runner: CommandRunner, downloader: ToolDownloading,
         pins: [InfraTool: ToolPin] = ToolPins.all, versionTimeout: TimeInterval = 5,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         spaceFreeRoot: URL = ToolResolver.defaultSpaceFreeRoot()) {
        self.searchPath = searchPath
        self.managedRoot = managedRoot
        self.runner = runner
        self.downloader = downloader
        self.pins = pins
        self.versionTimeout = versionTimeout
        self.environment = environment
        self.spaceFreeRoot = spaceFreeRoot
    }

    /// The Python candidates for gcloud, newest first after the user's own `CLOUDSDK_PYTHON`.
    static let pythonNames = ["python3.13", "python3.12", "python3.11", "python3.10", "python3"]
    static let pythonMissing = "gcloud needs Python 3.10+ (brew install python@3.12)"

    func resolve(_ tool: InfraTool, provision: Bool,
                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ResolvedTool {
        guard let pin = pins[tool] else { throw ToolError.missing(tool, "no pin for \(tool.rawValue)") }

        // gcloud is unusable without a 3.10+ Python — its darwin tarball bundles none and
        // macOS's own is 3.9 — so that is settled first: there is no point finding, let alone
        // downloading, a gcloud that cannot start. Its version check then runs with the Python.
        var extra: [String: String] = [:]
        if tool == .gcloud {
            guard let python = await usablePython() else { throw ToolError.missing(.gcloud, Self.pythonMissing) }
            extra["CLOUDSDK_PYTHON"] = python.path
        }

        var passedOver: [String] = []
        for candidate in candidates(for: tool) {
            switch await probe(candidate, pin, extra) {
            case .compatible(let version):
                return ResolvedTool(tool: tool, url: candidate, version: version, source: .path, environment: extra)
            case .incompatible(let version):
                passedOver.append("found \(version) at \(candidate.path)")
            case .unreadable:
                passedOver.append("found \(candidate.path) but could not read its version")
            }
        }

        if let managed = managedBinary(for: tool), FileManager.default.isExecutableFile(atPath: managed.path),
           case .compatible(let version) = await probe(managed, pin, extra) {
            return ResolvedTool(tool: tool, url: managed, version: version, source: .managed, environment: extra)
        }

        let found = passedOver.isEmpty ? "\(tool.rawValue) not found" : passedOver.joined(separator: "; ")
        let why = "\(found), need \(pin.rangeDescription)"
        guard let version = pin.managedVersion, let asset = pin.assetURL, let sha256 = pin.sha256 else {
            throw ToolError.missing(tool, why + "; Flight Deck does not install \(tool.rawValue)")
        }
        guard provision else {
            throw ToolError.missing(tool, why + "; Flight Deck can download \(tool.rawValue) \(version)")
        }
        return try await provisionManaged(pin, version: version, asset: asset, sha256: sha256, extra: extra,
                                          progress: progress)
    }

    /// The user's login PATH, then the two Homebrew prefixes, then Tailscale.app's own binary
    /// directory — which answers CLI arguments, and is the only copy a Mac App Store install has.
    /// De-duplicated, first occurrence kept. Blocks on a login shell the first time (at most
    /// `LoginShellPath.timeoutSeconds`), so never call it on the main actor.
    static func defaultSearchPath() -> [URL] {
        let login = (LoginShellPath.resolve() ?? "").split(separator: ":").map(String.init)
        let tailscaleApp = (TailscaleCLI.appBinary as NSString).deletingLastPathComponent
        var seen = Set<String>()
        return (login + ["/opt/homebrew/bin", "/usr/local/bin", tailscaleApp])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `Application Support/Flight Deck/tools`, following a `-FlightDeckStateDir` override and
    /// the Debug build's own directory like every other piece of app state.
    @MainActor
    static func defaultManagedRoot() -> URL {
        (FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
            .appendingPathComponent("tools", isDirectory: true)
    }

    /// `~/Library/Caches/dev.flightdeck/tools`: the managed AWS CLI's home, because its pkg
    /// refuses an install directory containing a space and every Application Support path has
    /// one. A cache is the right class of directory for it anyway — a re-download replaces it —
    /// and it is shared by Debug and Release, which is safe for checksum-pinned binaries.
    static func defaultSpaceFreeRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("dev.flightdeck/tools", isDirectory: true)
    }

    /// Lowercase hex SHA-256, streamed: a gcloud tarball is far too large to hash in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The version a tool's banner reports, read only after the tool's own prefix, so another
    /// number in the banner (aws's `Python/3.11`, gcloud's `bq 2.1.8`) can never be mistaken
    /// for it. Tailscale prints the bare version as its first line.
    static func version(in output: String, of tool: InfraTool) -> SemVer? {
        switch tool {
        case .tofu: version(after: "OpenTofu v", in: output)
        case .aws: version(after: "aws-cli/", in: output)
        case .gcloud: version(after: "Google Cloud SDK ", in: output)
        case .tailscale: version(after: "", in: String(output.split(separator: "\n").first ?? "")
            .trimmingCharacters(in: .whitespaces))
        }
    }

    /// The version immediately after `prefix` (or at the very start, for an empty prefix).
    static func version(after prefix: String, in output: String) -> SemVer? {
        let tail: Substring
        if prefix.isEmpty { tail = Substring(output) } else {
            guard let range = output.range(of: prefix) else { return nil }
            tail = output[range.upperBound...]
        }
        guard let match = tail.prefixMatch(of: #/\d+\.\d+(?:\.\d+)?/#) else { return nil }
        return SemVer.parse(String(match.output))
    }

    // MARK: - Search

    /// One executable per search directory. Tailscale.app names its binary `Tailscale`, which a
    /// case-sensitive volume would not find under `tailscale`.
    private func candidates(for tool: InfraTool) -> [URL] {
        let names = tool == .tailscale ? [tool.rawValue, "Tailscale"] : [tool.rawValue]
        var seen = Set<String>()
        return searchPath.compactMap { dir in
            names.lazy.map { dir.appendingPathComponent($0) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The absolute path a managed copy of `tool` runs from, unpacked or not; nil for a tool
    /// Flight Deck never provisions.
    func managedBinary(for tool: InfraTool) -> URL? {
        guard let pin = pins[tool], let version = pin.managedVersion else { return nil }
        return managedDirectory(pin).appendingPathComponent(version)
            .appendingPathComponent(pin.managedBinary ?? pin.tool.rawValue)
    }

    /// `<root>/<tool>`, where root is `spaceFreeRoot` for a pin that needs one.
    private func managedDirectory(_ pin: ToolPin) -> URL {
        (pin.requiresSpaceFreePath ? spaceFreeRoot : managedRoot).appendingPathComponent(pin.tool.rawValue, isDirectory: true)
    }

    // MARK: - gcloud's Python

    /// The first interpreter reporting Python 3.10+: the user's `CLOUDSDK_PYTHON` (a path, or a
    /// name looked up on the search path), then `pythonNames` on the search path.
    private func usablePython() async -> URL? {
        var candidates: [URL] = []
        if let configured = environment["CLOUDSDK_PYTHON"], !configured.isEmpty {
            candidates += configured.contains("/") ? [URL(fileURLWithPath: configured)]
                : searchPath.map { $0.appendingPathComponent(configured) }
        }
        candidates += Self.pythonNames.flatMap { name in searchPath.map { $0.appendingPathComponent(name) } }
        var seen = Set<String>()
        let minimum = SemVer(major: 3, minor: 10, patch: 0)
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted
            && FileManager.default.isExecutableFile(atPath: candidate.path) {
            guard let output = await versionOutput(candidate, ["--version"], [:]),
                  let version = Self.version(after: "Python ", in: output) else { continue }
            if version.major == 3, version >= minimum { return candidate }
        }
        return nil
    }

    // MARK: - Version probe

    private enum Probe { case compatible(SemVer), incompatible(SemVer), unreadable }

    private func probe(_ binary: URL, _ pin: ToolPin, _ extra: [String: String]) async -> Probe {
        guard let output = await versionOutput(binary, pin.versionArgs, extra),
              let version = Self.version(in: output, of: pin.tool) else { return .unreadable }
        return pin.accepts(version) ? .compatible(version) : .incompatible(version)
    }

    /// `<binary> <versionArgs>`'s stdout and stderr, or nil on a nonzero exit or timeout. The run
    /// gets its own process group, so the timeout's cancellation reaches whatever a wrapper
    /// script forked (gcloud's `bin/gcloud` is a shell script that runs Python) — killing only
    /// the leader would leave the pipe open and the read blocked until the grandchild exits.
    private func versionOutput(_ binary: URL, _ arguments: [String], _ extra: [String: String]) async -> String? {
        let runner = runner, timeout = versionTimeout
        let environment = probeEnvironment().merging(extra) { _, new in new }
        return try? await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = try await runner.run(executable: binary.path, arguments: arguments,
                                                  cwd: FileManager.default.temporaryDirectory, environment: environment,
                                                  processGroup: true, onSpawn: nil)
                guard result.exitCode == 0 else { return nil }
                return String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// The inherited environment with the search path in front: a wrapper script (gcloud's, a
    /// Homebrew `aws`) finds its interpreter the way it would in the user's shell, even in an app
    /// launched from the Dock with launchd's bare PATH.
    private func probeEnvironment() -> [String: String] {
        var environment = self.environment
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (searchPath.map(\.path) + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    // MARK: - Managed copy

    /// Download, verify, unpack into a staging directory beside the destination, then rename it
    /// into place — so a crash mid-unpack leaves a `.staging-*` directory that is never mistaken
    /// for a usable copy, and nothing under `managedRoot` exists at all for a download that
    /// failed its checksum.
    private func provisionManaged(_ pin: ToolPin, version: String, asset: URL, sha256: String,
                                  extra: [String: String],
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> ResolvedTool {
        let tool = pin.tool
        let toolDir = managedDirectory(pin)
        // Checked before downloading: the pkg would fail half-way through its install, after a
        // 60 MB download, on a path a misconfigured root slipped a space into.
        if pin.requiresSpaceFreePath, toolDir.path.contains(" ") {
            throw ToolError.downloadFailed(tool, "\(toolDir.path) contains a space, which the \(tool.rawValue) installer refuses")
        }
        let download: URL
        do { download = try await downloader.fetch(asset, progress: progress) }
        catch let error as ToolError { throw error }
        catch { throw ToolError.downloadFailed(tool, error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: download) }

        guard (try? Self.sha256(of: download)) == sha256.lowercased() else { throw ToolError.checksumMismatch(tool) }

        let fm = FileManager.default
        let staging = toolDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let destination = toolDir.appendingPathComponent(version, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch { throw ToolError.downloadFailed(tool, "cannot create \(staging.path): \(error.localizedDescription)") }
        defer { try? fm.removeItem(at: staging) }

        try await unpack(download, asset: asset, into: staging, tool: tool)

        // Reaching here means the managed copy at `destination`, if any, already failed its
        // version check in `resolve`: it is replaced, not trusted.
        try? fm.removeItem(at: destination)
        do { try fm.moveItem(at: staging, to: destination) }
        catch { throw ToolError.downloadFailed(tool, "cannot move into \(destination.path): \(error.localizedDescription)") }

        guard let binary = managedBinary(for: tool), case .compatible(let found) = await probe(binary, pin, extra) else {
            throw ToolError.downloadFailed(tool, "the unpacked \(tool.rawValue) \(version) did not report a compatible version")
        }
        progress(1)
        return ResolvedTool(tool: tool, url: binary, version: found, source: .managed, environment: extra)
    }

    /// By the asset's extension: `ditto` for zip (keeps the executable bit), `tar` for a gzipped
    /// tarball, and the per-user `installer` for the AWS pkg, pointed at `staging` through a
    /// `customLocation` choice — the documented "install for the current user" route, which
    /// needs no admin rights and puts the CLI at `<staging>/aws-cli/aws`.
    private func unpack(_ archive: URL, asset: URL, into staging: URL, tool: InfraTool) async throws {
        let command: (String, [String])
        var choices: URL?
        switch asset.pathExtension {
        case "zip":
            command = ("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        case "gz", "tgz":
            command = ("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        case "pkg":
            let xml = FileManager.default.temporaryDirectory.appendingPathComponent("flightdeck-choices-\(UUID().uuidString).xml")
            do { try Self.customLocationChoices(staging).write(to: xml) }
            catch { throw ToolError.downloadFailed(tool, "cannot write installer choices: \(error.localizedDescription)") }
            choices = xml
            command = ("/usr/sbin/installer", ["-pkg", archive.path, "-target", "CurrentUserHomeDirectory",
                                               "-applyChoiceChangesXML", xml.path])
        default:
            throw ToolError.downloadFailed(tool, "no unpacker for \(asset.lastPathComponent)")
        }
        defer { if let choices { try? FileManager.default.removeItem(at: choices) } }

        let result: CommandResult
        do {
            result = try await runner.run(executable: command.0, arguments: command.1,
                                          cwd: FileManager.default.temporaryDirectory,
                                          environment: ProcessInfo.processInfo.environment)
        } catch { throw ToolError.downloadFailed(tool, "\(command.0) failed: \(error.localizedDescription)") }
        guard result.exitCode == 0 else {
            throw ToolError.downloadFailed(tool, "\(command.0) exited \(result.exitCode): \(result.stderr)")
        }
    }

    /// AWS's documented choice-changes plist for a per-user install: the `default` choice's
    /// `customLocation` is the directory the `aws-cli/` folder is created in.
    static func customLocationChoices(_ location: URL) throws -> Data {
        let choices: [[String: String]] = [[
            "choiceAttribute": "customLocation",
            "attributeSetting": location.path,
            "choiceIdentifier": "default",
        ]]
        return try PropertyListSerialization.data(fromPropertyList: choices, format: .xml, options: 0)
    }
}
