import FleetKit
import HostKit
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

    func testClipboardOAuthCaptureNeedsBothParts() throws {
        let h = try CloudSetupHarness(clipboard: "client id: kExample\nclient secret: tskey-client-kExample-SECRET")
        XCTAssertTrue(try h.model.captureOAuthClientFromClipboard())
        XCTAssertEqual(h.savedOAuth?.id, "kExample")
        let h2 = try CloudSetupHarness(clipboard: "just some text")
        XCTAssertFalse(try h2.model.captureOAuthClientFromClipboard())
    }

    // MARK: - Beyond the brief

    /// The client is recorded against the tailnet this Mac is on, or `mode()` would call it a
    /// mismatch and tailnet mode would never turn on.
    func testCapturedClientIsForThisMacsTailnet() throws {
        let h = try CloudSetupHarness(clipboard: "tskey-client-kExample-SECRET\nkExample")
        XCTAssertTrue(try h.model.captureOAuthClientFromClipboard())
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
