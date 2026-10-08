import FleetKit
import HostKit
import IntakeKit
import XCTest
@testable import FlightDeck

@MainActor
final class CloudSetupModelTests: XCTestCase {
    func testTailscaleStepsSkipWhenNotRunning() async throws {
        let m = try CloudSetupHarness(tailnet: .notRunning).model
        await m.refresh()
        for id in [CloudSetupModel.StepID.policy, .oauth, .lock] { XCTAssertTrue(m.steps.first { $0.id == id }!.skipped, "\(id)") }
    }

    func testSignedOutAWSOffersSignIn() async throws {
        let m = try CloudSetupHarness(aws: .signedOut(fix: "aws sso login --profile dev")).model
        await m.refresh()
        let s = m.steps.first { $0.id == .aws }!
        XCTAssertEqual(s.state, .failed); XCTAssertEqual(s.action, "Sign in")
    }

    func testQuotaTooLowOpensIncreasePage() async throws {
        let h = try CloudSetupHarness(quota: QuotaCheck(ok: false, have: 0, need: 4, increaseURL: URL(string: "https://example.invalid/quota")!))
        await h.model.perform(.quota)
        XCTAssertEqual(h.opened, [URL(string: "https://example.invalid/quota")!])
    }

    func testPolicyFallsBackToCopyAndOpenWhenUnpatchable() async throws {
        let h = try CloudSetupHarness(policy: "[not, an, object]")
        let patch = await h.model.applyPolicy(token: "tskey-api-EXAMPLE")
        XCTAssertNil(patch)
        XCTAssertTrue(h.copied?.contains("tag:flightdeck-cloud") == true)
        XCTAssertEqual(h.opened.last?.host, "login.tailscale.com")
    }

    func testClipboardOAuthCaptureNeedsBothParts() async throws {
        let h = try CloudSetupHarness(clipboard: "client id: kExample\nclient secret: tskey-client-kExample-SECRET")
        let captured = try await h.model.captureOAuthClientFromClipboard()
        XCTAssertTrue(captured)
        XCTAssertEqual(h.savedOAuth?.id, "kExample")
        let h2 = try CloudSetupHarness(clipboard: "just some text")
        let none = try await h2.model.captureOAuthClientFromClipboard()
        XCTAssertFalse(none)
    }

    // MARK: - Beyond the brief

    /// The client is recorded against the tailnet this Mac is on, or `mode()` would call it a
    /// mismatch and tailnet mode would never turn on.
    func testCapturedClientIsForThisMacsTailnet() async throws {
        let h = try CloudSetupHarness(clipboard: "tskey-client-kExample-SECRET\nkExample")
        let captured = try await h.model.captureOAuthClientFromClipboard()
        XCTAssertTrue(captured)
        XCTAssertEqual(h.savedOAuth, TailscaleOAuthClient(id: "kExample", secret: "tskey-client-kExample-SECRET",
                                                          tailnet: "example-tailnet.ts.net"))
    }

    func testPatchablePolicyIsShownThenWrittenWithItsETag() async throws {
        let h = try CloudSetupHarness(policy: "{\n  // ours\n  \"acls\": []\n}\n")
        let applied = await h.model.applyPolicy(token: "tskey-api-EXAMPLE")
        let patch = try XCTUnwrap(applied)
        XCTAssertTrue(patch.diff.contains("+"), patch.diff)
        XCTAssertNil(h.copied, "nothing copied when the patch can be applied")
        try await h.model.confirmPolicy(patch, token: "tskey-api-EXAMPLE")
        let write = try XCTUnwrap(h.http.requests.last { $0.method == "POST" })
        XCTAssertEqual(write.headers["If-Match"], "\"e1\"")
        XCTAssertTrue(String(decoding: write.body ?? Data(), as: UTF8.self).contains("// ours"))
        XCTAssertEqual(h.model.steps.first { $0.id == .policy }?.state, .ok)
    }

    func testSkippingACloudLeavesItOutOfTheQuotaCheck() async throws {
        let h = try CloudSetupHarness(quota: QuotaCheck(ok: false, have: 0, need: 4, increaseURL: URL(string: "https://example.invalid/quota")!))
        h.model.skip(.aws)
        await h.model.perform(.quota)
        XCTAssertEqual(h.opened, [])
        XCTAssertTrue(h.model.steps.first { $0.id == .aws }!.skipped)
    }

    /// The whole test step against fakes: a 15-minute machine of the cheapest allowlisted type,
    /// `uname -a` run on it by name, and destroyed — the time and cost reported.
    func testRunTestUpsRunsUnameAndDestroys() async throws {
        let h = try CloudSetupHarness()
        h.infra.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.infra.hostComesOnline(after: .applied)
        h.runOutput = "Linux fd-setup-test 6.8.0-1012-aws aarch64 GNU/Linux\n"
        await h.model.runTest()
        let step = try XCTUnwrap(h.model.steps.first { $0.id == .test })
        XCTAssertEqual(step.state, .ok, step.detail)
        XCTAssertTrue(step.detail.contains("Linux fd-setup-test"), step.detail)
        XCTAssertTrue(step.detail.contains("est."), step.detail)
        XCTAssertEqual(h.ran.map(\.host), [CloudSetupModel.testMachineName])
        XCTAssertEqual(h.ran.first?.command, ["uname", "-a"])
        let vars = try XCTUnwrap(h.infra.tofu.environments.first)
        XCTAssertEqual(vars["AWS_PROFILE"], "example")
        XCTAssertTrue(h.infra.tofu.destroyed.contains(CloudSetupModel.testMachineName))
        XCTAssertNil(h.infra.registry.machine(named: CloudSetupModel.testMachineName), "nothing left running")
    }

    func testRunTestDestroysTheMachineWhenTheRunFails() async throws {
        let h = try CloudSetupHarness()
        h.infra.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.infra.hostComesOnline(after: .applied)
        h.runError = CloudSetupError.tailscaleNotRunning
        await h.model.runTest()
        XCTAssertEqual(h.model.steps.first { $0.id == .test }?.state, .failed)
        XCTAssertTrue(h.infra.tofu.destroyed.contains(CloudSetupModel.testMachineName))
        XCTAssertNil(h.infra.registry.machine(named: CloudSetupModel.testMachineName))
    }

    /// The ID is only ever the one the secret carries: any other `k…` word on the clipboard
    /// (a "key:" label, another client's ID) is never taken for it.
    func testOAuthIDComesOnlyFromTheSecretsOwnID() {
        XCTAssertNil(CloudSetupModel.parseOAuthClient("client id: kOther\nsecret: tskey-client-kExample-SECRET"))
        XCTAssertNil(CloudSetupModel.parseOAuthClient("key tskey-client-kExample-SECRET"))
        XCTAssertEqual(CloudSetupModel.parseOAuthClient("kOther kExample tskey-client-kExample-SECRET")?.id, "kExample")
    }

    /// The secret is cleared off the clipboard once it is in the Keychain — asked for by the
    /// secret itself, so the app clears only a clipboard that still holds it.
    func testCaptureAsksToClearTheSecretFromTheClipboard() async throws {
        let h = try CloudSetupHarness(clipboard: "kExample tskey-client-kExample-SECRET")
        _ = try await h.model.captureOAuthClientFromClipboard()
        XCTAssertEqual(h.clearedSecrets, ["tskey-client-kExample-SECRET"])
        let h2 = try CloudSetupHarness(clipboard: "nothing")
        _ = try await h2.model.captureOAuthClientFromClipboard()
        XCTAssertEqual(h2.clearedSecrets, [])
    }

    func testTestRunThatHangsIsAbandonedAndTheMachineDestroyed() async throws {
        let h = try CloudSetupHarness()
        h.testRunTimeout = 0.2
        h.infra.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.infra.hostComesOnline(after: .applied)
        h.runOutput = "never"
        h.spies.runDelay = 30
        await h.model.runTest()
        let step = try XCTUnwrap(h.model.steps.first { $0.id == .test })
        XCTAssertEqual(step.state, .failed)
        XCTAssertTrue(step.detail.contains("did not finish"), step.detail)
        XCTAssertTrue(h.infra.tofu.destroyed.contains(CloudSetupModel.testMachineName))
    }

    // MARK: - GCP: Compute Engine API (spec §9)

    func testEnablingComputeOpensTheConsoleWhenNotPermitted() async throws {
        let h = try CloudSetupHarness()
        let page = URL(string: "https://console.cloud.google.com/apis/library/compute.googleapis.com?project=example-project")!
        h.infra.gcpAccount.computeResult = .success(.needsConsole(page))
        await h.model.refresh()
        XCTAssertEqual(h.model.step(.gcp).action, CloudSetupModel.enableComputeAction)
        await h.model.perform(.gcp)
        XCTAssertEqual(h.infra.gcpAccount.computeCalls, 1)
        XCTAssertEqual(h.opened, [page])
    }

    func testEnablingComputeThatWorksOpensNothing() async throws {
        let h = try CloudSetupHarness()
        await h.model.refresh()
        await h.model.perform(.gcp)
        XCTAssertEqual(h.infra.gcpAccount.computeCalls, 1)
        XCTAssertEqual(h.opened, [])
        XCTAssertEqual(h.model.step(.gcp).state, .ok)
        XCTAssertTrue(h.model.step(.gcp).detail.contains("Compute Engine API is enabled"), h.model.step(.gcp).detail)
    }

    // MARK: - Tools: download progress

    /// A download that reports halfway, then fails: what reached the sheet is the progress.
    struct HalfwayDownload: ToolDownloading {
        func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            progress(0.5)
            throw ToolError.downloadFailed(.aws, "offline")
        }
    }

    func testToolsStepPublishesDownloadProgress() async throws {
        let h = try CloudSetupHarness()
        let tofu = try FakeExecutable.make("tofu", script: "echo 'OpenTofu v1.8.11'")
        let root = h.infra.root
        h.infra.resolver = ToolResolver(searchPath: [tofu.deletingLastPathComponent()], managedRoot: root.appendingPathComponent("m"),
                                        runner: SystemCommandRunner(), downloader: HalfwayDownload(),
                                        environment: ["PATH": "/usr/bin:/bin"], spaceFreeRoot: root.appendingPathComponent("s"))
        h.model.skip(.gcp)
        var seen: [Double] = []
        let sink = h.model.$toolProgress.sink { if let p = $0 { seen.append(p) } }
        defer { sink.cancel() }
        await h.model.perform(.tools)
        XCTAssertTrue(seen.contains(0.5), "\(seen)")
        XCTAssertNil(h.model.toolProgress, "cleared once the step is done")
    }

    // MARK: - Allowlist editing

    func testAllowlistDraftParsesOnlyOnCommitAndKeepsWhatIsTyped() {
        var draft = AllowlistDraft(patterns: ["t3.*"])
        XCTAssertEqual(draft.text, "t3.*")
        draft.text = "t4g.*, "
        XCTAssertEqual(draft.text, "t4g.*, ", "a trailing comma survives typing")
        draft.text = "t4g.*, m7g.*large"
        XCTAssertEqual(draft.commit(), ["t4g.*", "m7g.*large"])
        draft.text = "  "
        XCTAssertNil(draft.commit(), "an emptied field keeps the previous value")
    }

    // MARK: - Launch never holds the main actor

    /// `resumeAfterLaunch` reaches OpenTofu, whose environment starts from the login shell's.
    /// That lookup must run off the main actor: a main-actor ticker keeps ticking while it blocks.
    func testResumeAfterLaunchAsksForTheBaseEnvironmentOffMain() async throws {
        let h = try InfraHarness()
        let probe = BaseEnvironmentProbe()
        h.baseEnvironment = { probe.slowLookup() }
        try h.readyMachine("gpu")
        var m = try XCTUnwrap(h.registry.machine(named: "gpu"))
        m.state = .destroying
        try h.registry.upsert(m)
        let ticker = Task { @MainActor in
            while !Task.isCancelled { probe.tick(); try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        await h.service.resumeAfterLaunch()
        ticker.cancel()
        XCTAssertEqual(probe.calls, 1)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertGreaterThan(probe.ticksDuringLookup, 3, "the main actor was free while the lookup blocked")
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
    }

    // MARK: - Live wiring helpers

    func testPublicIPAcceptsOnlyAnIPv4Address() async throws {
        let url = InfraLive.checkIPURL.absoluteString
        let good = FakeHTTP(responses: [url: "203.0.113.9\n"])
        let ip = try await InfraLive.publicIP(http: good)
        XCTAssertEqual(ip, "203.0.113.9")
        for bad in ["<html>captive portal</html>", "203.0.113", "203.0.113.256", "2001:db8::1", ""] {
            do { _ = try await InfraLive.publicIP(http: FakeHTTP(responses: [url: bad])); XCTFail(bad) } catch {}
        }
    }

    func testControllerIDIsMintedOnceAndKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("infra-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try InfraLive.controllerID(directory: dir)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(try InfraLive.controllerID(directory: dir), first)
    }

    func testGCPProjectsAreListedThroughGcloud() async throws {
        let gc = try FakeExecutable.make("gcloud", script: #"""
        echo "$@" > "$(dirname "$0")/args"
        echo '[{"projectId":"example-project","name":"Example"},{"projectId":"example-two"}]'
        """#)
        let projects = try await GCPAccount(gcloud: gc, project: nil, runner: SystemCommandRunner()).projects()
        XCTAssertEqual(projects, ["example-project", "example-two"])
        let args = try String(contentsOf: gc.deletingLastPathComponent().appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.hasPrefix("projects list --format=json"), args)
    }

    func testGCPComputeAPIEnabledOrPointedAtTheConsole() async throws {
        let ok = try FakeExecutable.make("gcloud", script: #"echo "$@" > "$(dirname "$0")/args""#)
        let enabled = try await GCPAccount(gcloud: ok, project: "example-project", runner: SystemCommandRunner()).enableComputeAPI()
        XCTAssertEqual(enabled, .enabled)
        let args = try String(contentsOf: ok.deletingLastPathComponent().appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.hasPrefix("services enable compute.googleapis.com --project example-project"), args)

        let denied = try FakeExecutable.make("gcloud", script: "echo 'ERROR: (gcloud.services.enable) PERMISSION_DENIED: Permission denied to enable service' >&2; exit 1")
        let result = try await GCPAccount(gcloud: denied, project: "example-project", runner: SystemCommandRunner()).enableComputeAPI()
        XCTAssertEqual(result, .needsConsole(URL(string: "https://console.cloud.google.com/apis/library/compute.googleapis.com?project=example-project")!))

        let broken = try FakeExecutable.make("gcloud", script: "echo 'ERROR: network unreachable' >&2; exit 1")
        do { _ = try await GCPAccount(gcloud: broken, project: "example-project", runner: SystemCommandRunner()).enableComputeAPI(); XCTFail() }
        catch {}
    }

    func testCloudPreferencesDefaultToTheSpecsBudgetAndSurviveAnOldBlob() throws {
        let old = try JSONEncoder().encode(Preferences())
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertNil(decoded.cloud)
        let store = PreferencesStore(persistence: nil)
        XCTAssertEqual(store.cloud.budget, .default)
        XCTAssertEqual(store.cloud.budget.monthlyCapUSD, 50)
        XCTAssertEqual(store.cloud.budget.maxConcurrent, 2)
        store.updateCloud { $0.awsProfile = "dev"; $0.budget.monthlyCapUSD = 75 }
        let round = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(store.preferences))
        XCTAssertEqual(round.cloud?.awsProfile, "dev")
        XCTAssertEqual(round.cloud?.budget.monthlyCapUSD, 75)
    }
}

/// Where `env.baseEnvironment` ran, and how many main-actor ticks happened while it blocked.
final class BaseEnvironmentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _ticks = 0, _calls = 0, _during = 0, _onMain = false
    var calls: Int { lock.withLock { _calls } }
    var ranOnMain: Bool { lock.withLock { _onMain } }
    var ticksDuringLookup: Int { lock.withLock { _during } }
    func tick() { lock.withLock { _ticks += 1 } }

    /// Blocks its thread for 300 ms, as a login shell's first lookup can for seconds.
    func slowLookup() -> [String: String] {
        let start = lock.withLock { () -> Int in
            _calls += 1
            _onMain = pthread_main_np() != 0
            return _ticks
        }
        Thread.sleep(forTimeInterval: 0.3)
        lock.withLock { _during = _ticks - start }
        return ["PATH": "/usr/bin:/bin"]
    }
}
