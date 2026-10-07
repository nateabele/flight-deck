import IntakeKit
import XCTest
@testable import FlightDeck

/// `ToolResolver` against a fake `PATH` of shell scripts that print version banners, and fake
/// downloaders. Nothing here touches the network or runs an installer: a managed copy is only
/// ever reached through `ToolDownloading`, and every downloader below is a stub.
final class ToolResolverTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A fake tool: a shell script printing `output` for any arguments.
    func fake(_ name: String, prints output: String, in sub: String = "bin") throws {
        let url = dir.appendingPathComponent(sub).appendingPathComponent(name)
        try "#!/bin/sh\necho '\(output)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    struct NoDownload: ToolDownloading { func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { throw ToolError.downloadFailed(.tofu, "offline") } }

    func resolver(_ downloader: ToolDownloading = NoDownload()) -> ToolResolver {
        ToolResolver(searchPath: [dir.appendingPathComponent("bin")], managedRoot: dir.appendingPathComponent("managed"),
                     runner: SystemCommandRunner(), downloader: downloader)
    }

    func testUsesCompatibleCopyOnPath() async throws {
        try fake("tofu", prints: "OpenTofu v1.8.3\non darwin_arm64")
        let r = try await resolver().resolve(.tofu, provision: false)
        XCTAssertEqual(r.source, .path); XCTAssertEqual(r.version, SemVer(major: 1, minor: 8, patch: 3))
    }

    func testTooOldOnPathIsNotUsed() async throws {
        try fake("tofu", prints: "OpenTofu v1.6.0")
        do { _ = try await resolver().resolve(.tofu, provision: false); XCTFail() }
        catch ToolError.missing(.tofu, let why) { XCTAssertTrue(why.contains("1.6.0"), why) }
    }

    func testNextMajorIsNotUsed() async throws {
        try fake("tofu", prints: "OpenTofu v2.0.0")
        do { _ = try await resolver().resolve(.tofu, provision: false); XCTFail() } catch ToolError.missing {}
    }

    func testUnparseableVersionIsNotUsed() async throws {
        try fake("aws", prints: "something odd")
        do { _ = try await resolver().resolve(.aws, provision: false); XCTFail() } catch ToolError.missing {}
    }

    func testAWSAndGcloudVersionShapes() async throws {
        try fake("aws", prints: "aws-cli/2.17.4 Python/3.11 Darwin/25 exe/arm64")
        try fake("gcloud", prints: "Google Cloud SDK 495.0.0\nbq 2.1.8")
        let r = resolver()
        let aws = try await r.resolve(.aws, provision: false)
        let gc = try await r.resolve(.gcloud, provision: false)
        XCTAssertEqual(aws.version.minor, 17); XCTAssertEqual(gc.version.major, 495)
    }

    func testTailscaleIsNeverProvisioned() async throws {
        do { _ = try await resolver().resolve(.tailscale, provision: true); XCTFail() }
        catch ToolError.missing(.tailscale, _) {}
    }

    func testChecksumMismatchIsHardFailure() async throws {
        struct BadDownload: ToolDownloading {
            let file: URL
            func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { file }
        }
        let junk = dir.appendingPathComponent("junk.zip"); try Data("nope".utf8).write(to: junk)
        do { _ = try await resolver(BadDownload(file: junk)).resolve(.tofu, provision: true); XCTFail() }
        catch ToolError.checksumMismatch(.tofu) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("managed/tofu").path),
                       "nothing is unpacked from an unverified download")
    }

    func testPrefersPathOverManaged() async throws {
        try fake("tofu", prints: "OpenTofu v1.9.0")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("managed/tofu/1.8.3"), withIntermediateDirectories: true)
        try fake("tofu", prints: "OpenTofu v1.8.3", in: "managed/tofu/1.8.3")
        let resolved = try await resolver().resolve(.tofu, provision: false)
        XCTAssertEqual(resolved.source, .path)
    }

    func testSemVerParse() {
        XCTAssertEqual(SemVer.parse("v1.8.3"), SemVer(major: 1, minor: 8, patch: 3))
        XCTAssertEqual(SemVer.parse("495.0.0"), SemVer(major: 495, minor: 0, patch: 0))
        XCTAssertEqual(SemVer.parse("1.70"), SemVer(major: 1, minor: 70, patch: 0))
        XCTAssertNil(SemVer.parse("x"))
    }

    // MARK: - Beyond the brief: the managed path, end to end with a stub downloader

    /// A downloader that hands back a copy of `file` (the resolver deletes what it is given).
    struct CopyDownload: ToolDownloading {
        let file: URL
        func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            progress(1)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: copy)
            return copy
        }
    }

    /// A pin whose checksum is the SHA-256 of a real zip built here, so the verify-then-unpack
    /// path runs for real (`ditto`), and the unpacked fake answers the version check.
    func testVerifiedDownloadIsUnpackedAndUsed() async throws {
        let stage = dir.appendingPathComponent("stage"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try fake("tofu", prints: "OpenTofu v1.8.11", in: "stage")
        let zip = dir.appendingPathComponent("tofu.zip")
        let made = try await SystemCommandRunner().run(executable: "/usr/bin/ditto", arguments: ["-c", "-k", stage.path, zip.path],
                                                       cwd: dir, environment: ProcessInfo.processInfo.environment)
        XCTAssertEqual(made.exitCode, 0, made.stderr)
        let pin = ToolPin(tool: .tofu, minimum: SemVer(major: 1, minor: 8, patch: 0), belowMajor: 2, managedVersion: "1.8.11",
                          assetURL: URL(string: "https://example.invalid/tofu.zip"), sha256: try ToolResolver.sha256(of: zip),
                          versionArgs: ["--version"], managedBinary: "tofu")
        let r = ToolResolver(searchPath: [dir.appendingPathComponent("bin")], managedRoot: dir.appendingPathComponent("managed"),
                             runner: SystemCommandRunner(), downloader: CopyDownload(file: zip), pins: [.tofu: pin])
        let resolved = try await r.resolve(.tofu, provision: true)
        XCTAssertEqual(resolved.source, .managed)
        XCTAssertEqual(resolved.version, SemVer(major: 1, minor: 8, patch: 11))
        XCTAssertEqual(resolved.url.path, dir.appendingPathComponent("managed/tofu/1.8.11/tofu").path)

        // Already unpacked: found again without provisioning, and without a downloader.
        let again = try await ToolResolver(searchPath: [], managedRoot: dir.appendingPathComponent("managed"),
                                           runner: SystemCommandRunner(), downloader: NoDownload(), pins: [.tofu: pin])
            .resolve(.tofu, provision: false)
        XCTAssertEqual(again.source, .managed)
    }

    /// Without `provision`, a missing tool is reported, never downloaded.
    func testNoProvisionNeverDownloads() async throws {
        struct Exploding: ToolDownloading {
            func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
                XCTFail("downloaded without provision"); throw ToolError.downloadFailed(.tofu, "x")
            }
        }
        do { _ = try await resolver(Exploding()).resolve(.tofu, provision: false); XCTFail() }
        catch ToolError.missing(.tofu, _) {}
    }

    /// The first compatible copy wins, even behind an incompatible one earlier on the path.
    func testSkipsIncompatibleForLaterCompatible() async throws {
        try fake("tofu", prints: "OpenTofu v1.6.0")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin2"), withIntermediateDirectories: true)
        try fake("tofu", prints: "OpenTofu v1.10.2", in: "bin2")
        let r = ToolResolver(searchPath: [dir.appendingPathComponent("bin"), dir.appendingPathComponent("bin2")],
                             managedRoot: dir.appendingPathComponent("managed"), runner: SystemCommandRunner(), downloader: NoDownload())
        let resolved = try await r.resolve(.tofu, provision: false)
        XCTAssertEqual(resolved.url.path, dir.appendingPathComponent("bin2/tofu").path)
    }

    /// A hung `--version` costs the timeout, not the caller's whole flow.
    func testHungVersionProbeTimesOut() async throws {
        let url = dir.appendingPathComponent("bin/tofu")
        try "#!/bin/sh\nexec sleep 30\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let r = ToolResolver(searchPath: [dir.appendingPathComponent("bin")], managedRoot: dir.appendingPathComponent("managed"),
                             runner: SystemCommandRunner(), downloader: NoDownload(), versionTimeout: 0.5)
        let start = Date()
        do { _ = try await r.resolve(.tofu, provision: false); XCTFail() } catch ToolError.missing(.tofu, _) {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testTailscaleBareVersionShape() async throws {
        try fake("tailscale", prints: "1.102.4\n  tailscale commit: abc")
        let resolved = try await resolver().resolve(.tailscale, provision: false)
        XCTAssertEqual(resolved.version, SemVer(major: 1, minor: 102, patch: 4))
    }
}
