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
        // Billing began with the apply; down ends it even though the machine never came up.
        XCTAssertEqual(h.ledger.spent(name: "gpu", now: h.now.addingTimeInterval(3600)), h.ledger.spent(name: "gpu", now: h.now))
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
        // Destroyed before it is forgotten: the instance is gone, but its security group and
        // the rest of tfstate may not be.
        XCTAssertNil(h.registry.machine(named: "d")); XCTAssertTrue(h.tofu.destroyed.contains("d"))
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

/// Collects each concurrent `up`'s outcome by name.
@MainActor
final class Outcomes {
    var byName: [String: Result<InfraMachine, Error>] = [:]
}

extension InfraServiceTests {
    // MARK: - Fix round 1

    /// Two `up`s for one name at once: exactly one proceeds; the other is refused at once and
    /// never touches the record the first one owns.
    func testConcurrentUpsOfOneNameRefuseTheSecond() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let service = h.service, repo = h.repo, config = gpu
        let outcomes = Outcomes()
        for i in 0..<2 {
            Task {
                do { outcomes.byName["\(i)"] = .success(try await service.up(name: "gpu", config: config, repoRoot: repo) { _ in }) }
                catch { outcomes.byName["\(i)"] = .failure(error) }
            }
        }
        try await waitUntil { outcomes.byName.count == 2 }
        let ready = outcomes.byName.values.compactMap { try? $0.get() }
        let refused = outcomes.byName.values.compactMap { r -> String? in
            if case .failure(InfraError.refused(let why)) = r { return why }; return nil
        }
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(refused, ["gpu is already being created or destroyed"])
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .ready)
        XCTAssertEqual(h.hosts.registry.hosts.map(\.name), ["gpu"])
    }

    /// A `down` while the `up` is still applying is refused too, and leaves the record alone.
    func testDownWhileUpIsInFlightIsRefused() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        h.tofu.holdApply = true
        let service = h.service, repo = h.repo, config = gpu
        let first = Task { try await service.up(name: "gpu", config: config, repoRoot: repo) { _ in } }
        try await waitUntil { self.h.tofu.calls.contains("apply") }
        let before = h.registry.machine(named: "gpu")
        do { try await service.down(name: "gpu") { _ in }; XCTFail() }
        catch InfraError.refused(let why) { XCTAssertEqual(why, "gpu is already being created or destroyed") }
        XCTAssertEqual(h.registry.machine(named: "gpu"), before)
        await h.tofu.applyGate.open()
        let m = try await first.value
        XCTAssertEqual(m.state, .ready)
    }

    /// The concurrency guardrail counts launches still in flight: with a limit of one, two `up`s
    /// for different names cannot both pass it.
    func testMaxConcurrentCountsLaunchesInFlight() async throws {
        h.budget.maxConcurrent = 1
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        h.tofu.holdApply = true
        let service = h.service, repo = h.repo, config = gpu
        let outcomes = Outcomes()
        for name in ["gpu", "db"] {
            Task {
                do { outcomes.byName[name] = .success(try await service.up(name: name, config: config, repoRoot: repo) { _ in }) }
                catch { outcomes.byName[name] = .failure(error) }
            }
        }
        try await waitUntil { outcomes.byName.count == 1 }
        await h.tofu.applyGate.open()
        try await waitUntil { outcomes.byName.count == 2 }
        let refused = outcomes.byName.values.filter { r in
            if case .failure(InfraError.preflight(let checks)) = r { return checks.contains { $0.name == "budget" && !$0.ok } }
            return false
        }
        XCTAssertEqual(refused.count, 1)
        XCTAssertEqual(outcomes.byName.values.compactMap { try? $0.get() }.count, 1)
        XCTAssertEqual(h.tofu.calls.filter { $0 == "apply" }.count, 1)
    }

    /// The enroll window runs from when the machine began enrolling, not from creation: one that
    /// became `enrolling` 6 minutes in and is relaunched at 10.5 minutes still has 5.5 minutes.
    func testRelaunchWaitsOutTheEnrollWindowFromWhenEnrollingBegan() async throws {
        let slot = try h.hosts.enroll(key: .mint(), name: "f", endpoints: ["198.51.100.9:47410"]).slot
        let m = InfraMachine.fixture(name: "f", state: .enrolling, slot: slot, createdAt: h.now.addingTimeInterval(-630),
                                     deadline: h.now.addingTimeInterval(3000), enrollingSince: h.now.addingTimeInterval(-270))
        try h.registry.upsert(m)
        try h.prepareWorkdir("f")
        XCTAssertEqual(h.service.enrollWait(for: m, now: h.now), 330, accuracy: 0.001)
        let harness: InfraHarness = h
        Task { try? await Task.sleep(nanoseconds: 200_000_000); harness.hostOnline("f") }
        await h.service.resumeAfterLaunch()
        XCTAssertEqual(h.registry.machine(named: "f")?.state, .ready)
        XCTAssertFalse(h.tofu.destroyed.contains("f"))
    }

    /// Records `enrollingSince` as the machine starts enrolling.
    func testUpRecordsWhenEnrollingBegan() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        XCTAssertEqual(m.enrollingSince, h.now)
    }

    /// If the spend ledger cannot be closed, the machine is not forgotten: it would bill forever.
    func testDownKeepsTheRecordWhenTheLedgerCannotClose() async throws {
        try h.registry.upsert(.fixture(name: "gpu"))
        try h.prepareWorkdir("gpu")
        try h.ledger.open(name: "gpu", hourlyUSD: 0.5, at: h.now.addingTimeInterval(-600))
        let file = h.root.appendingPathComponent("infra-ledger.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await h.service.down(name: "gpu") { _ in }; XCTFail() } catch {}
        let m = try XCTUnwrap(h.registry.machine(named: "gpu"))
        XCTAssertEqual(m.state, .failed)
        XCTAssertTrue(m.failure?.contains("ledger") == true, m.failure ?? "")
    }

    /// Progress reaches the caller in order and before the terminal event, success or failure.
    func testProgressArrivesBeforeTheOutcome() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        var events: [InfraEvent] = []
        _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { events.append($0) }
        let progress = try XCTUnwrap(events.firstIndex(of: .progress("create aws_instance.this")), "\(events)")
        let cost = try XCTUnwrap(events.firstIndex { if case .cost = $0 { return true }; return false })
        XCTAssertLessThan(progress, cost)

        events = []
        h.tofu.failApply = TofuError.failed(step: "apply", message: "boom")
        do { _ = try await h.service.up(name: "db", config: gpu, repoRoot: h.repo) { events.append($0) }; XCTFail() } catch {}
        let failedProgress = try XCTUnwrap(events.firstIndex(of: .progress("create aws_instance.this")), "\(events)")
        let failed = try XCTUnwrap(events.firstIndex { if case .failed = $0 { return true }; return false })
        XCTAssertLessThan(failedProgress, failed)
    }

    // MARK: - Orphans (spec §7.3)

    func testOrphansAreOwnedResourcesNoMachineAccountsFor() async throws {
        try h.registry.upsert(.fixture(name: "gpu"))                         // instance i-1
        try h.registry.upsert(.fixture(name: "web"))
        h.account.owned = [
            OwnedResource(cloud: "aws", kind: .instance, id: "i-1", region: "us-east-1", name: nil),          // by ID
            OwnedResource(cloud: "aws", kind: .securityGroup, id: "sg-1", region: "us-east-1", name: "web"),  // by name
            OwnedResource(cloud: "aws", kind: .instance, id: "i-9", region: "eu-west-1", name: "lost"),
            OwnedResource(cloud: "aws", kind: .securityGroup, id: "sg-9", region: "eu-west-1", name: nil),
        ]
        let orphans = await h.service.orphans()
        XCTAssertEqual(orphans.map(\.id), ["i-9", "sg-9"])
        XCTAssertEqual(h.account.owners, [h.service.ownerLabel], "asked for this controller's resources only")
    }

    /// A GCP machine records `projects/<p>/zones/<z>/instances/<name>`; the scan lists the bare name.
    func testGCPInstanceIsAccountedForByItsResourceName() async throws {
        var m = InfraMachine.fixture(name: "gpu", cloud: "gcp")
        m.instanceID = "projects/example-project/zones/us-central1-a/instances/fd-0a1b-gpu"
        try h.registry.upsert(m)
        let gcp = h.gcpAccount
        gcp.owned = [OwnedResource(cloud: "gcp", kind: .instance, id: "fd-0a1b-gpu", region: "us-central1-a", name: nil)]
        let orphans = await h.service.orphans()
        XCTAssertEqual(orphans, [])
    }

    func testDownOrphanDeletesOnlyAnOrphan() async throws {
        try h.registry.upsert(.fixture(name: "gpu"))
        let lost = OwnedResource(cloud: "aws", kind: .instance, id: "i-9", region: "eu-west-1", name: "lost")
        h.account.owned = [OwnedResource(cloud: "aws", kind: .instance, id: "i-1", region: "us-east-1", name: "gpu"), lost]
        do { try await h.service.downOrphan(id: "i-1"); XCTFail("a known machine is never an orphan") }
        catch InfraError.notFound(let id) { XCTAssertEqual(id, "i-1") }
        try await h.service.downOrphan(id: "i-9")
        XCTAssertEqual(h.account.deleted, [lost])
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
