import XCTest
import IntakeKit
@testable import FlightDeck

/// Collects progress from a `@Sendable` callback.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TofuProgress] = []
    func append(_ p: TofuProgress) { lock.lock(); items.append(p); lock.unlock() }
    var value: [TofuProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Drives LiveTofuRunner against a fake `tofu` script.
final class TofuRunnerTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func fakeTofu(_ body: String) throws -> URL {
        let u = dir.appendingPathComponent("tofu")
        try "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }
    func runner(_ tofu: URL) -> LiveTofuRunner {
        LiveTofuRunner(tofu: tofu, pluginCache: dir, runner: SystemCommandRunner(), environment: ["PATH": "/usr/bin:/bin"])
    }

    func testApplyStreamsJSONProgress() async throws {
        let tofu = try fakeTofu("""
        echo '{"@level":"info","type":"apply_start","hook":{"resource":{"addr":"aws_instance.this"},"action":"create"}}'
        echo '{"@level":"info","type":"apply_complete","hook":{"resource":{"addr":"aws_instance.this"},"action":"create"}}'
        """)
        let seen = ProgressLog()
        try await runner(tofu).apply(workdir: dir) { seen.append($0) }
        XCTAssertEqual(seen.value, [TofuProgress(resource: "aws_instance.this", action: "create", done: false),
                                    TofuProgress(resource: "aws_instance.this", action: "create", done: true)])
    }

    func testFailureCarriesTheDiagnostic() async throws {
        let tofu = try fakeTofu("""
        echo '{"@level":"error","type":"diagnostic","diagnostic":{"summary":"UnauthorizedOperation","detail":"not allowed"}}'
        exit 1
        """)
        do { try await runner(tofu).apply(workdir: dir) { _ in }; XCTFail("expected a failure") }
        catch TofuError.failed(let step, let message) {
            XCTAssertEqual(step, "apply"); XCTAssertTrue(message.contains("UnauthorizedOperation"))
        }
    }

    func testInitFailureFallsBackToStderr() async throws {
        let tofu = try fakeTofu("echo 'no such provider' >&2\nexit 1")
        do { try await runner(tofu).initialize(workdir: dir); XCTFail("expected a failure") }
        catch TofuError.failed(let step, let message) {
            XCTAssertEqual(step, "init"); XCTAssertTrue(message.contains("no such provider"))
        }
    }

    func testOutputsParse() async throws {
        let tofu = try fakeTofu(#"echo '{"fd_address":{"value":"198.51.100.7"},"fd_instance_id":{"value":"i-0abc"},"fd_hourly_usd":{"value":0.8}}'"#)
        let out = try await runner(tofu).outputs(workdir: dir)
        XCTAssertEqual(out, TofuOutputs(address: "198.51.100.7", instanceID: "i-0abc", hourlyUSD: 0.8))
    }

    func testMissingAddressIsAnError() async throws {
        let tofu = try fakeTofu(#"echo '{}'"#)
        do { _ = try await runner(tofu).outputs(workdir: dir); XCTFail("expected a failure") }
        catch TofuError.missingOutput("fd_address") {}
    }

    func testRefreshShowsGoneOnInstanceDeleteDrift() async throws {
        let tofu = try fakeTofu("""
        echo '{"type":"resource_drift","change":{"resource":{"addr":"aws_instance.this"},"action":"delete"}}'
        exit 2
        """)
        let gone = try await runner(tofu).refreshShowsGone(workdir: dir)
        XCTAssertTrue(gone)
    }

    func testRefreshCleanIsNotGone() async throws {
        let gone = try await runner(try fakeTofu("exit 0")).refreshShowsGone(workdir: dir)
        XCTAssertFalse(gone)
    }

    func testRefreshIgnoresNonInstanceDrift() async throws {
        let tofu = try fakeTofu("""
        echo '{"type":"resource_drift","change":{"resource":{"addr":"aws_security_group.this"},"action":"delete"}}'
        exit 2
        """)
        let gone = try await runner(tofu).refreshShowsGone(workdir: dir)
        XCTAssertFalse(gone)
    }

    /// Only the compute resource's own type counts: `aws_instance_profile` merely contains
    /// "instance", and its deletion is not a gone machine.
    func testRefreshAnchorsOnTheInstanceResourceType() async throws {
        let profile = try fakeTofu("""
        echo '{"type":"resource_drift","change":{"resource":{"addr":"aws_instance_profile.this"},"action":"delete"}}'
        exit 2
        """)
        let profileGone = try await runner(profile).refreshShowsGone(workdir: dir)
        XCTAssertFalse(profileGone)
        let gce = try fakeTofu("""
        echo '{"type":"resource_drift","change":{"resource":{"addr":"module.box.google_compute_instance.this[0]"},"action":"delete"}}'
        exit 2
        """)
        let gceGone = try await runner(gce).refreshShowsGone(workdir: dir)
        XCTAssertTrue(gceGone)
    }
}
