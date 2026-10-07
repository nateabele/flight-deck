import XCTest
import IntakeKit
@testable import FlightDeck

/// `AWSAccount` and `GCPAccount` against fake `aws`/`gcloud` scripts. The real CLIs are never
/// run: a real one would read the developer's live credentials, and sign-in opens a browser.
final class CloudAccountsTests: XCTestCase {
    var log: URL!
    override func setUp() {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-calls-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: log) }

    // MARK: - AWS

    func testAWSProfilesFromConfig() {
        let text = "[default]\nregion = us-east-1\n[profile dev]\nsso_session = s\n[sso-session s]\nsso_start_url = https://example.invalid\n"
        XCTAssertEqual(AWSAccount.profiles(configText: text), ["default", "dev"])
    }

    func testAWSReadyFromCallerIdentity() async throws {
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log) + "\n"
            + #"echo '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/x/y"}'"#)
        let s = await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).status()
        XCTAssertEqual(s, .ready(identity: "123456789012"))
        XCTAssertEqual(FakeExecutable.calls(log), ["sts get-caller-identity --output json --profile dev"])
    }

    func testAWSExpiredSSOSaysHowToFix() async throws {
        let aws = try FakeExecutable.make("aws", script: "echo 'Error when retrieving token from sso: Token has expired and refresh failed' >&2; exit 255")
        guard case .signedOut(let fix) = await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).status() else { return XCTFail() }
        XCTAssertTrue(fix.contains("aws sso login --profile dev"), fix)
    }

    func testAWSNoCredentialsWithoutProfileSaysConfigureSSO() async throws {
        let aws = try FakeExecutable.make("aws", script: "echo 'Unable to locate credentials. You can configure credentials by running \"aws configure\".' >&2; exit 253")
        guard case .signedOut(let fix) = await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).status() else { return XCTFail() }
        XCTAssertTrue(fix.contains("aws configure sso"), fix)
    }

    func testAWSOtherFailureIsUnavailableWithTheMessage() async throws {
        let aws = try FakeExecutable.make("aws", script: "echo 'Could not connect to the endpoint URL' >&2; exit 255")
        guard case .unavailable(let why) = await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).status() else { return XCTFail() }
        XCTAssertTrue(why.contains("Could not connect"), why)
    }

    func testAWSQuotaForGPUFamily() async throws {
        // G and VT on-demand vCPU quota L-DB2E81BA; g6.xlarge needs 4 vCPU.
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log) + "\n" + """
        case "$1" in
          ec2) echo '4' ;;
          *) echo '{"Quota":{"Value":0.0}}' ;;
        esac
        """)
        let q = try await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).quota(region: "us-east-1", instanceType: "g6.xlarge")
        XCTAssertFalse(q.ok); XCTAssertEqual(q.need, 4); XCTAssertEqual(q.have, 0); XCTAssertNotNil(q.increaseURL)
        XCTAssertEqual(q.increaseURL?.absoluteString,
                       "https://us-east-1.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-DB2E81BA")
        let calls = FakeExecutable.calls(log)
        XCTAssertTrue(calls.contains { $0.hasPrefix("ec2 describe-instance-types --instance-types g6.xlarge") && $0.contains("--region us-east-1") }, "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region us-east-1") }, "\(calls)")
    }

    func testAWSQuotaSufficient() async throws {
        let aws = try FakeExecutable.make("aws", script: """
        case "$1" in
          ec2) echo '2' ;;
          *) echo '{"Quota":{"Value":32.0}}' ;;
        esac
        """)
        let q = try await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).quota(region: "eu-west-1", instanceType: "t3.small")
        XCTAssertEqual(q, QuotaCheck(ok: true, have: 32, need: 2,
                                     increaseURL: URL(string: "https://eu-west-1.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A")))
    }

    func testAWSQuotaCodesByFamily() {
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "m7i.large", spot: false), "L-1216C47A")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "im4gn.large", spot: false), "L-1216C47A")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "g6.xlarge", spot: false), "L-DB2E81BA")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "vt1.3xlarge", spot: false), "L-DB2E81BA")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "p5.48xlarge", spot: false), "L-417A185B")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "c7g.large", spot: true), "L-34B43A08")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "g5.xlarge", spot: true), "L-3819A6DF")
        XCTAssertEqual(AWSAccount.quotaCode(instanceType: "p4d.24xlarge", spot: true), "L-7212CCBC")
        XCTAssertNil(AWSAccount.quotaCode(instanceType: "mac2.metal", spot: false))
    }

    func testAWSQuotaForUnknownFamilyThrows() async throws {
        let aws = try FakeExecutable.make("aws", script: "echo '4'")
        do { _ = try await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).quota(region: "us-east-1", instanceType: "mac2.metal"); XCTFail() }
        catch CloudAccountError.unsupportedInstanceType(let t) { XCTAssertEqual(t, "mac2.metal") }
    }

    func testAWSSignInRunsSSOLogin() async throws {
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log))
        try await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).signIn()
        XCTAssertEqual(FakeExecutable.calls(log), ["sso login --profile dev"])
    }

    func testAWSProviderEnvironment() {
        let aws = URL(fileURLWithPath: "/nonexistent/aws")
        XCTAssertEqual(AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).providerEnvironment(), ["AWS_PROFILE": "dev"])
        XCTAssertEqual(AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).providerEnvironment(), [:])
    }

    // MARK: - GCP

    func testGCPSignedOutWhenNoADC() async throws {
        let gc = try FakeExecutable.make("gcloud", script: "echo 'ERROR: (gcloud.auth.application-default.print-access-token) Your default credentials were not found.' >&2; exit 1")
        guard case .signedOut(let fix) = await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner()).status() else { return XCTFail() }
        XCTAssertTrue(fix.contains("gcloud auth application-default login"), fix)
    }

    func testGCPReadyNamesTheProject() async throws {
        let gc = try FakeExecutable.make("gcloud", script: FakeExecutable.record(to: log) + "\necho 'ya29.not-a-real-token'")
        let s = await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner()).status()
        XCTAssertEqual(s, .ready(identity: "example-project"))
        XCTAssertEqual(FakeExecutable.calls(log), ["auth application-default print-access-token"])
    }

    func testGCPQuotaChecksGPUsForG2() async throws {
        let gc = try FakeExecutable.make("gcloud", script: FakeExecutable.record(to: log) + "\n" + #"""
        case "$2" in
          machine-types) echo '[{"name":"g2-standard-4","guestCpus":4,"accelerators":[{"guestAcceleratorCount":1,"guestAcceleratorType":"nvidia-l4"}]}]' ;;
          regions) echo '{"quotas":[{"metric":"CPUS","limit":24.0,"usage":0.0},{"metric":"G2_CPUS","limit":24.0,"usage":4.0},{"metric":"NVIDIA_L4_GPUS","limit":1.0,"usage":1.0}]}' ;;
        esac
        """#)
        let q = try await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner())
            .quota(region: "us-central1", instanceType: "g2-standard-4")
        // CPUs fit (20 free of G2_CPUS); the one L4 is already in use, so the GPU check fails.
        XCTAssertFalse(q.ok); XCTAssertEqual(q.have, 0); XCTAssertEqual(q.need, 1)
        XCTAssertEqual(q.increaseURL?.absoluteString, "https://console.cloud.google.com/iam-admin/quotas?project=example-project")
        let calls = FakeExecutable.calls(log)
        XCTAssertTrue(calls.contains { $0.hasPrefix("compute regions describe us-central1") && $0.contains("--project example-project") }, "\(calls)")
    }

    func testGCPQuotaUsesFamilyCPUMetric() async throws {
        let gc = try FakeExecutable.make("gcloud", script: #"""
        case "$2" in
          machine-types) echo '[{"name":"n2-standard-8","guestCpus":8}]' ;;
          regions) echo '{"quotas":[{"metric":"CPUS","limit":2.0,"usage":0.0},{"metric":"N2_CPUS","limit":24.0,"usage":8.0}]}' ;;
        esac
        """#)
        let q = try await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner())
            .quota(region: "europe-west4", instanceType: "n2-standard-8")
        XCTAssertTrue(q.ok); XCTAssertEqual(q.have, 16); XCTAssertEqual(q.need, 8)
    }

    func testGCPCPUMetricByFamily() {
        XCTAssertEqual(GCPAccount.cpuMetric(machineType: "e2-small"), "CPUS")
        XCTAssertEqual(GCPAccount.cpuMetric(machineType: "n1-standard-1"), "CPUS")
        XCTAssertEqual(GCPAccount.cpuMetric(machineType: "n2d-standard-2"), "N2D_CPUS")
        XCTAssertEqual(GCPAccount.cpuMetric(machineType: "g2-standard-4"), "G2_CPUS")
        XCTAssertEqual(GCPAccount.gpuMetric(acceleratorType: "nvidia-l4"), "NVIDIA_L4_GPUS")
        XCTAssertEqual(GCPAccount.gpuMetric(acceleratorType: "nvidia-tesla-t4"), "NVIDIA_T4_GPUS")
    }

    func testGCPSignInRunsADCLogin() async throws {
        let gc = try FakeExecutable.make("gcloud", script: FakeExecutable.record(to: log))
        try await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner()).signIn()
        XCTAssertEqual(FakeExecutable.calls(log), ["auth application-default login"])
    }

    func testGCPProviderEnvironment() {
        let env = GCPAccount(gcloud: URL(fileURLWithPath: "/nonexistent/gcloud"), project: "example-project",
                             runner: SystemCommandRunner()).providerEnvironment()
        XCTAssertEqual(env, ["GOOGLE_CLOUD_PROJECT": "example-project", "CLOUDSDK_CORE_PROJECT": "example-project"])
    }
}
