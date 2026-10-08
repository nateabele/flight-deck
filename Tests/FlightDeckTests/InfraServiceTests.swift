import CryptoKit
import FleetKit
import HostKit
import IntakeKit
import XCTest
@testable import FlightDeck

@MainActor
final class InfraServiceTests: XCTestCase {
    var h: InfraHarness!
    override func setUp() async throws { h = try InfraHarness() }
    override func tearDown() async throws { h = nil }

    let gpu = InfraConfig(source: .preset("aws-linux"), region: "us-east-1", instanceType: "t3.small", arch: nil, diskGB: nil,
                          spot: false, ttl: .init(seconds: 3600), idle: .init(seconds: 1800), autoUp: false, vars: [:], maxHourly: nil)

    func testUpCreatesEnrollsAndBecomesReady() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { self.h.events.append($0) }
        XCTAssertEqual(m.state, .ready); XCTAssertEqual(m.network, .public)
        XCTAssertEqual(m.allowCIDR, "203.0.113.9/32")                 // from env.publicIP fake
        XCTAssertEqual(h.hosts.registry.hosts.map(\.name), ["gpu"])
        XCTAssertEqual(h.hosts.registry.hosts[0].endpoints, ["198.51.100.7:47410"])
        let vars = try h.tfvars("gpu")
        XCTAssertEqual(vars["fd_allow_cidr"] as? String, "203.0.113.9/32")
        XCTAssertTrue((vars["fd_user_data"] as? String)?.contains("enroll --file") == true)
        XCTAssertEqual((vars["fd_labels"] as? [String: String])?["flightdeck-name"], "gpu")
        XCTAssertTrue(h.events.contains { if case .cost = $0 { return true }; return false })
        XCTAssertEqual(h.tofu.calls, ["init", "apply", "output"])
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .ready)
        XCTAssertEqual(m.hourlyUSD, 0.5)
    }

    func testPreflightRefusesBeforeAnyTofuCall() async throws {
        h.budget.allowedTypes["aws"] = []                      // nothing allowed
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.preflight(let checks) { XCTAssertTrue(checks.contains { !$0.ok && $0.name == "budget" }) }
        XCTAssertEqual(h.tofu.calls, [], "nothing created")
        XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
        XCTAssertNil(h.registry.machine(named: "gpu"))
    }

    /// Review Focus 3.
    func testNameClashRefusedBeforeCreate() async throws {
        try h.hosts.enroll(key: .mint(), name: "gpu", endpoints: [])
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.nameInUse(let why) { XCTAssertTrue(why.contains("paired host"), why) }
        try h.registry.upsert(.fixture(name: "db", repoRoot: "/other/repo"))
        do { _ = try await h.service.up(name: "db", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.nameInUse(let why) { XCTAssertTrue(why.contains("/other/repo"), why) }
        XCTAssertEqual(h.tofu.calls, [])
    }

    /// Review Focus 2.
    func testFailedApplyIsStillDestroyable() async throws {
        h.tofu.failApply = TofuError.failed(step: "apply", message: "InsufficientInstanceCapacity")
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { self.h.events.append($0) }; XCTFail() } catch {}
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .failed)
        XCTAssertTrue(h.registry.machine(named: "gpu")?.failure?.contains("InsufficientInstanceCapacity") == true)
        XCTAssertTrue(h.events.contains { if case .failed = $0 { return true }; return false })
        try await h.service.down(name: "gpu") { _ in }
        XCTAssertEqual(h.tofu.calls.last, "destroy")
        XCTAssertNil(h.registry.machine(named: "gpu")); XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
    }

    /// Review Focus 1.
    func testRelaunchMidProvisionResumesOrDestroys() async throws {
        // Enrolled-but-never-confirmed: host comes online after relaunch → adopted as ready.
        try h.registry.upsert(.fixture(name: "a", state: .enrolling, slot: try h.hosts.enroll(key: .mint(), name: "a", endpoints: ["198.51.100.7:47410"]).slot))
        // Provisioning with a deadline already passed → destroyed.
        try h.registry.upsert(.fixture(name: "b", state: .provisioning, deadline: h.now.addingTimeInterval(-1)))
        try h.prepareWorkdir("b")
        h.hostOnline("a")
        await h.service.resumeAfterLaunch()
        XCTAssertEqual(h.registry.machine(named: "a")?.state, .ready)
        XCTAssertNil(h.registry.machine(named: "b")); XCTAssertTrue(h.tofu.destroyed.contains("b"))
    }

    func testEnrollTimeoutFailsWithConsoleOutput() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.consoleOutput = "cloud-init: curl: (6) Could not resolve host"
        h.enrollTimeout = 0.05
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.enrollTimeout(let console) { XCTAssertTrue(console?.contains("Could not resolve") == true) }
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .failed)
    }

    func testTailnetModeUsesTailnetAddressAndNoInboundRule() async throws {
        h.tailnetAvailable(nodeIP: "100.64.0.9")
        h.tofu.outputs = TofuOutputs(address: "10.0.0.4", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        XCTAssertEqual(m.network, .tailnet); XCTAssertNil(m.allowCIDR)
        XCTAssertEqual(h.hosts.registry.hosts[0].endpoints, ["100.64.0.9:47410"])
        XCTAssertEqual(try h.tfvars("gpu")["fd_allow_cidr"] as? String, "")
        XCTAssertEqual(h.publicIPCalls, 0)
        let userData = try XCTUnwrap(try h.tfvars("gpu")["fd_user_data"] as? String)
        XCTAssertTrue(userData.contains("--auth-key=tskey-auth-EXAMPLE"))
        XCTAssertTrue(userData.contains("--hostname=fd-gpu"))
    }

    func testCostLineFormat() throws {
        let m = InfraMachine.fixture(name: "gpu", instanceType: "g6.xlarge", hourlyUSD: 0.8,
                                     createdAt: h.now.addingTimeInterval(-4320), deadline: h.now.addingTimeInterval(10_080))
        try h.ledger.open(name: "gpu", hourlyUSD: 0.8, at: m.createdAt)
        XCTAssertEqual(h.service.costLine(for: m, now: h.now), "gpu · g6.xlarge · $0.80/h est. · up 1h12m · ~$0.96 · TTL 2h48m · month ~$0.96 of $50")
        h.budget.monthlyCapUSD = nil
        XCTAssertEqual(h.service.costLine(for: m, now: h.now), "gpu · g6.xlarge · $0.80/h est. · up 1h12m · ~$0.96 · TTL 2h48m · month ~$0.96")
    }

    // MARK: - Carried rulings (task-14-carries.md)

    /// Carry 6: the owner label is 12 lowercase hex characters of SHA-256 of this controller's
    /// id, because the GCP preset cuts it at 12 and a hex prefix keeps 48 random bits.
    func testLabelsCarryTheHashedOwnerAndTheName() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        let labels = try XCTUnwrap(try h.tfvars("gpu")["fd_labels"] as? [String: String])
        let digest = SHA256.hash(data: Data(h.controllerID.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(labels, ["flightdeck": "1", "flightdeck-owner": String(digest.prefix(12)), "flightdeck-name": "gpu"])
    }

    /// Carries 9 and 7: the timer gets an absolute deadline of creation + TTL, the preset its TTL
    /// in seconds, and the module the region and type.
    func testPresetVarsAndAbsoluteDeadline() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        let vars = try h.tfvars("gpu")
        XCTAssertEqual(vars["ttl_seconds"] as? Double, 3600)
        XCTAssertEqual(vars["region"] as? String, "us-east-1")
        XCTAssertEqual(vars["instance_type"] as? String, "t3.small")
        XCTAssertEqual(vars["fd_name"] as? String, "gpu")
        XCTAssertNil(vars["arch"], "null lets the preset derive it")
        XCTAssertEqual(m.deadline, h.now.addingTimeInterval(3600))
        // 1_800_000_000 + 3600 is 2027-01-15 09:00:00 UTC.
        XCTAssertTrue((vars["fd_user_data"] as? String)?.contains("OnCalendar=2027-01-15 09:00:00 UTC") == true)
    }

    /// Carry 4: OpenTofu runs with the repaired base environment, the tool's own variables and
    /// the account's provider variables.
    func testTofuGetsTheAccountsProviderEnvironment() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        let env = try XCTUnwrap(h.tofu.environments.first)
        XCTAssertEqual(env["AWS_PROFILE"], "example")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/login/shell/bin")
    }

    /// Carry 3: two callers needing tofu at once share one resolution (and so one download).
    func testConcurrentToolResolutionIsSerialized() async throws {
        let log = h.root.appendingPathComponent("probes.log")
        let tofu = try FakeExecutable.make("tofu", script: FakeExecutable.record(to: log) + "\nsleep 0.3\necho 'OpenTofu v1.8.11'")
        h.resolver = ToolResolver(searchPath: [tofu.deletingLastPathComponent()], managedRoot: h.root.appendingPathComponent("t"),
                                  runner: SystemCommandRunner(), downloader: ToolResolverTests.NoDownload(),
                                  environment: ["PATH": "/usr/bin:/bin"], spaceFreeRoot: h.root.appendingPathComponent("t2"))
        let service = h.service
        async let a = service.tool(.tofu)
        async let b = service.tool(.tofu)
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, y)
        XCTAssertEqual(FakeExecutable.calls(log).count, 1, "one version probe for both callers")
    }

    /// Carry 12: an apply refused for missing permissions names the IAM actions the preset needs.
    func testUnauthorizedApplyNamesTheIAMActions() async throws {
        h.tofu.failApply = TofuError.failed(step: "apply", message: "api error UnauthorizedOperation: You are not authorized")
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() } catch {}
        let failure = try XCTUnwrap(h.registry.machine(named: "gpu")?.failure)
        XCTAssertTrue(failure.contains("ec2:RunInstances"), failure)
        XCTAssertTrue(failure.contains("servicequotas:GetServiceQuota"), failure)
        let checks = await h.service.doctor()
        let row = try XCTUnwrap(checks.first { $0.name == "machine gpu" })
        XCTAssertFalse(row.ok)
        XCTAssertTrue(row.fix?.contains("ec2:DescribeInstanceTypeOfferings") == true)
    }

    func testMaxHourlyBelowThePriceRefuses() async throws {
        var cheap = gpu
        cheap.maxHourly = 0.1
        do { _ = try await h.service.up(name: "gpu", config: cheap, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.preflight(let checks) {
            let budget = try XCTUnwrap(checks.first { $0.name == "budget" })
            XCTAssertFalse(budget.ok); XCTAssertTrue(budget.detail.contains("max_hourly"), budget.detail)
        }
        XCTAssertEqual(h.tofu.calls, [])
    }

    func testUpOfAReadyMachineFromTheSameRepoReturnsIt() async throws {
        try h.registry.upsert(.fixture(name: "gpu", repoRoot: h.repo.path))
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        XCTAssertEqual(m.name, "gpu"); XCTAssertEqual(h.tofu.calls, [])
    }

    func testDestroyFailureKeepsTheRecord() async throws {
        try h.registry.upsert(.fixture(name: "gpu"))
        try h.prepareWorkdir("gpu")
        h.tofu.failDestroy = TofuError.failed(step: "destroy", message: "throttled")
        do { try await h.service.down(name: "gpu") { _ in }; XCTFail() } catch {}
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .failed)
    }

    func testDownOfAnUnknownMachineIsNotFound() async {
        do { try await h.service.down(name: "nope") { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? InfraError, .notFound("nope")) }
    }

    /// Carry 11 (plan deviation 6): extend moves the controller deadline only up to the
    /// machine's own timer, which was fixed at creation.
    func testExtendStopsAtTheMachinesOwnTimer() async throws {
        let created = h.now.addingTimeInterval(-600)
        try h.registry.upsert(.fixture(name: "gpu", createdAt: created, deadline: created.addingTimeInterval(1800),
                                       machineDeadline: created.addingTimeInterval(3600)))
        let m = try await h.service.extend(name: "gpu", by: .init(seconds: 1800))
        XCTAssertEqual(m.deadline, created.addingTimeInterval(3600))
        XCTAssertEqual(h.registry.machine(named: "gpu")?.deadline, created.addingTimeInterval(3600))
        do { _ = try await h.service.extend(name: "gpu", by: .init(seconds: 60)); XCTFail() }
        catch InfraError.refused(let why) { XCTAssertTrue(why.contains("own timer was set at creation"), why) }
    }

    func testExtendRechecksTheBudget() async throws {
        let created = h.now.addingTimeInterval(-600)
        try h.registry.upsert(.fixture(name: "gpu", hourlyUSD: 4, createdAt: created, deadline: created.addingTimeInterval(1800),
                                       machineDeadline: created.addingTimeInterval(4 * 3600)))
        do { _ = try await h.service.extend(name: "gpu", by: .init(seconds: 3 * 3600)); XCTFail() }
        catch InfraError.refused(let why) { XCTAssertTrue(why.contains("per-machine cap"), why) }
        XCTAssertEqual(h.registry.machine(named: "gpu")?.deadline, created.addingTimeInterval(1800))
    }

    func testResumeRedestroysAMachineCaughtMidDestroyAndDropsAGoneOne() async throws {
        try h.registry.upsert(.fixture(name: "c", state: .destroying))
        try h.prepareWorkdir("c")
        try h.registry.upsert(.fixture(name: "d", state: .provisioning, deadline: h.now.addingTimeInterval(600)))
        try h.prepareWorkdir("d")
        h.tofu.refreshGone = true
        await h.service.resumeAfterLaunch()
        XCTAssertNil(h.registry.machine(named: "c")); XCTAssertTrue(h.tofu.destroyed.contains("c"))
        XCTAssertNil(h.registry.machine(named: "d")); XCTAssertFalse(h.tofu.destroyed.contains("d"))
    }

    func testResumeDestroysAnEnrollmentThatTimedOut() async throws {
        let slot = try h.hosts.enroll(key: .mint(), name: "e", endpoints: ["198.51.100.8:47410"]).slot
        try h.registry.upsert(.fixture(name: "e", state: .enrolling, slot: slot, createdAt: h.now.addingTimeInterval(-700),
                                       deadline: h.now.addingTimeInterval(3000)))
        try h.prepareWorkdir("e")
        await h.service.resumeAfterLaunch()
        XCTAssertNil(h.registry.machine(named: "e")); XCTAssertTrue(h.tofu.destroyed.contains("e"))
        XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
    }
}

@MainActor
final class HostServiceEnrollTests: XCTestCase {
    func testEnrollRefusesExistingName() throws {
        let s = HostService(registry: HostRegistry(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID()).json"),
                                                   secrets: InMemoryHostSecretStore()), controllerName: "t")
        try s.enroll(key: .mint(), name: "gpu", endpoints: [])
        XCTAssertThrowsError(try s.enroll(key: .mint(), name: "gpu", endpoints: []))
        XCTAssertThrowsError(try s.enroll(key: .mint(), name: "GPU", endpoints: []), "names are case-insensitive")
        XCTAssertEqual(s.registry.hosts.map(\.name), ["gpu"])
        XCTAssertEqual(s.registry.hosts[0].serviceName, "fd-gpu")
    }

    func testSetEndpointsRedialsTheNewAddress() throws {
        let dialer = InfraHostDialer()
        let s = HostService(registry: HostRegistry(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID()).json"),
                                                   secrets: InMemoryHostSecretStore()), controllerName: "t",
                            dial: dialer, clock: ManualHostLinkClock())
        let record = try s.enroll(key: .mint(), name: "gpu", endpoints: [])
        XCTAssertEqual(dialer.connections.count, 0, "nothing to dial yet")
        s.setEndpoints(slot: record.slot, ["198.51.100.7:47410"])
        XCTAssertEqual(s.registry.hosts[0].endpoints, ["198.51.100.7:47410"])
        XCTAssertEqual(dialer.connections.count, 1)
        dialer.bringUp(record.slot)
        XCTAssertEqual(s.statuses[record.slot], .online(hostName: "cloud"))
    }
}
