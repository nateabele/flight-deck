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

    // MARK: - Task 14 carries

    /// Carry 5: with no profile there is no SSO session to log into, so sign-in says how to
    /// make one instead of running a login that cannot work.
    func testAWSSignInWithoutProfilePointsAtConfigureSSO() async throws {
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log))
        do { try await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).signIn(); XCTFail() }
        catch CloudAccountError.failed(let why) { XCTAssertTrue(why.contains("aws configure sso"), why) }
        XCTAssertEqual(FakeExecutable.calls(log), [], "nothing run")
    }

    /// Carry 4: a CLI runs with the given base environment (the app's, PATH-repaired from the login
    /// shell) plus the resolved tool's own variables, its directory leading PATH.
    func testCLIEnvironmentCarriesTheToolsVariablesAndTheBasePath() async throws {
        let gc = try FakeExecutable.make("gcloud", script: #"echo "$CLOUDSDK_PYTHON|$PATH" >> '\#(log.path)'; echo token"#)
        _ = await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner(),
                             environment: ["CLOUDSDK_PYTHON": "/opt/example/python3.12"],
                             base: ["PATH": "/usr/bin:/bin:/login/shell/bin"]).status()
        let dir = gc.deletingLastPathComponent().path
        XCTAssertEqual(FakeExecutable.calls(log), ["/opt/example/python3.12|\(dir):/usr/bin:/bin:/login/shell/bin"])
    }

    /// Carry 10: the console output shown when a machine never enrolls.
    func testAWSConsoleOutput() async throws {
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log) + "\necho 'cloud-init: boot log'")
        let out = await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner())
            .consoleOutput(instanceID: "i-0abc", region: "us-east-1")
        XCTAssertEqual(out, "cloud-init: boot log")
        XCTAssertEqual(FakeExecutable.calls(log),
                       ["ec2 get-console-output --instance-id i-0abc --latest --output text --region us-east-1 --profile dev"])
    }

    func testGCPConsoleOutputFromTheInstanceID() async throws {
        let gc = try FakeExecutable.make("gcloud", script: FakeExecutable.record(to: log) + "\necho 'serial: boot log'")
        let out = await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner())
            .consoleOutput(instanceID: "projects/example-project/zones/us-central1-b/instances/fd-gpu-0a1b", region: "us-central1")
        XCTAssertEqual(out, "serial: boot log")
        XCTAssertEqual(FakeExecutable.calls(log),
                       ["compute instances get-serial-port-output fd-gpu-0a1b --zone us-central1-b --project example-project"])
    }

    // MARK: - Orphan scan (spec §7.3)

    /// Every enabled region is asked, because an orphan's region is exactly what nobody
    /// recorded; terminated instances are filtered out by the CLI, not reported as orphans.
    func testAWSListOwnedAsksEveryRegionForInstancesAndSecurityGroups() async throws {
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log) + "\n" + #"""
        case "$*" in
          *describe-regions*) echo '["us-east-1","eu-west-1"]' ;;
          *describe-instances*us-east-1*) echo '{"Reservations":[{"Instances":[{"InstanceId":"i-0abc","Tags":[{"Key":"flightdeck-owner","Value":"0a1b2c3d4e5f"},{"Key":"flightdeck-name","Value":"gpu"}]}]}]}' ;;
          *describe-instances*) echo '{"Reservations":[]}' ;;
          *describe-security-groups*eu-west-1*) echo '{"SecurityGroups":[{"GroupId":"sg-0def","GroupName":"fd-old","Tags":[{"Key":"flightdeck-name","Value":"old"}]}]}' ;;
          *describe-security-groups*) echo '{"SecurityGroups":[]}' ;;
        esac
        """#)
        let found = try await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).listOwned(owner: "0a1b2c3d4e5f")
        XCTAssertEqual(Set(found), [
            OwnedResource(cloud: "aws", kind: .instance, id: "i-0abc", region: "us-east-1", name: "gpu"),
            OwnedResource(cloud: "aws", kind: .securityGroup, id: "sg-0def", region: "eu-west-1", name: "old"),
        ])
        let calls = FakeExecutable.calls(log)
        XCTAssertTrue(calls.contains { $0.hasPrefix("ec2 describe-regions") && $0.contains("--profile dev") }, "\(calls)")
        for region in ["us-east-1", "eu-west-1"] {
            XCTAssertTrue(calls.contains {
                $0.hasPrefix("ec2 describe-instances") && $0.contains("Name=tag:flightdeck-owner,Values=0a1b2c3d4e5f")
                    && $0.contains("Name=instance-state-name,Values=pending,running,stopping,stopped")
                    && $0.contains("--region \(region)")
            }, "\(calls)")
            XCTAssertTrue(calls.contains {
                $0.hasPrefix("ec2 describe-security-groups") && $0.contains("Name=tag:flightdeck-owner,Values=0a1b2c3d4e5f")
                    && $0.contains("--region \(region)")
            }, "\(calls)")
        }
    }

    /// A region that cannot be read fails the scan: "no orphans" must never mean "did not look".
    func testAWSListOwnedFailsWhenARegionFails() async throws {
        let aws = try FakeExecutable.make("aws", script: #"""
        case "$*" in
          *describe-regions*) echo '["us-east-1"]' ;;
          *) echo 'UnauthorizedOperation' >&2; exit 254 ;;
        esac
        """#)
        do { _ = try await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).listOwned(owner: "0a1b2c3d4e5f"); XCTFail() }
        catch CloudAccountError.failed(let why) { XCTAssertTrue(why.contains("UnauthorizedOperation"), why) }
    }

    /// Output that is not the JSON asked for is a failure, never an empty list.
    func testAWSListOwnedRejectsBadJSON() async throws {
        let badRegions = try FakeExecutable.make("aws", script: "echo 'not json'")
        do { _ = try await AWSAccount(aws: badRegions, profile: nil, runner: SystemCommandRunner()).listOwned(owner: "0a1b2c3d4e5f"); XCTFail() }
        catch CloudAccountError.failed {}
        let badInstances = try FakeExecutable.make("aws", script: #"""
        case "$*" in
          *describe-regions*) echo '["us-east-1"]' ;;
          *describe-instances*) echo '<html>proxy error</html>' ;;
          *) echo '{"SecurityGroups":[]}' ;;
        esac
        """#)
        do { _ = try await AWSAccount(aws: badInstances, profile: nil, runner: SystemCommandRunner()).listOwned(owner: "0a1b2c3d4e5f"); XCTFail() }
        catch CloudAccountError.failed {}
    }

    func testGCPListOwnedRejectsBadJSON() async throws {
        let gc = try FakeExecutable.make("gcloud", script: #"""
        case "$2" in
          instances) echo '[]' ;;
          firewall-rules) echo '{"error":"unexpected"}' ;;
        esac
        """#)
        do { _ = try await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner()).listOwned(owner: "0a1b2c3d4e5f"); XCTFail() }
        catch CloudAccountError.failed {}
    }

    func testAWSDeleteOwned() async throws {
        let aws = try FakeExecutable.make("aws", script: FakeExecutable.record(to: log))
        let account = AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner())
        try await account.deleteOwned(OwnedResource(cloud: "aws", kind: .instance, id: "i-0abc", region: "us-east-1", name: "gpu"))
        try await account.deleteOwned(OwnedResource(cloud: "aws", kind: .securityGroup, id: "sg-0def", region: "eu-west-1", name: nil))
        XCTAssertEqual(FakeExecutable.calls(log), [
            "ec2 terminate-instances --instance-ids i-0abc --region us-east-1 --output json --profile dev",
            "ec2 delete-security-group --group-id sg-0def --region eu-west-1 --profile dev",
        ])
    }

    /// Firewalls carry no labels, so the owner is read from the description the preset writes.
    func testGCPListOwnedFindsInstancesByLabelAndFirewallsByDescription() async throws {
        let gc = try FakeExecutable.make("gcloud", script: FakeExecutable.record(to: log) + "\n" + #"""
        case "$2" in
          instances) echo '[{"id":"123","name":"fd-0a1b2c3d4e5f-gpu","zone":"https://www.googleapis.com/compute/v1/projects/example-project/zones/us-central1-a","labels":{"flightdeck-owner":"0a1b2c3d4e5f","flightdeck-name":"gpu"}}]' ;;
          firewall-rules) echo '[{"name":"fd-0a1b2c3d4e5f-gpu","description":"flightdeck-owner=0a1b2c3d4e5f flightdeck-name=gpu"},{"name":"someone-else","description":"flightdeck-owner=0a1b2c3d4e5f0 flightdeck-name=x"}]' ;;
        esac
        """#)
        let found = try await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner()).listOwned(owner: "0a1b2c3d4e5f")
        XCTAssertEqual(found, [
            OwnedResource(cloud: "gcp", kind: .instance, id: "fd-0a1b2c3d4e5f-gpu", region: "us-central1-a", name: "gpu"),
            OwnedResource(cloud: "gcp", kind: .firewall, id: "fd-0a1b2c3d4e5f-gpu", region: "global", name: "gpu"),
        ])
        let calls = FakeExecutable.calls(log)
        XCTAssertTrue(calls.contains { $0.hasPrefix("compute instances list --filter labels.flightdeck-owner=0a1b2c3d4e5f") && $0.contains("--project example-project") }, "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("compute firewall-rules list --filter description~flightdeck-owner=0a1b2c3d4e5f") }, "\(calls)")
    }

    func testGCPDeleteOwned() async throws {
        let gc = try FakeExecutable.make("gcloud", script: FakeExecutable.record(to: log))
        let account = GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner())
        try await account.deleteOwned(OwnedResource(cloud: "gcp", kind: .instance, id: "fd-x-gpu", region: "us-central1-a", name: "gpu"))
        try await account.deleteOwned(OwnedResource(cloud: "gcp", kind: .firewall, id: "fd-x-gpu", region: "global", name: "gpu"))
        XCTAssertEqual(FakeExecutable.calls(log), [
            "compute instances delete fd-x-gpu --zone us-central1-a --quiet --project example-project",
            "compute firewall-rules delete fd-x-gpu --quiet --project example-project",
        ])
    }

    func testConsoleOutputIsNilWhenTheCLIFails() async throws {
        let aws = try FakeExecutable.make("aws", script: "echo denied >&2; exit 255")
        let out = await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).consoleOutput(instanceID: "i-1", region: "us-east-1")
        XCTAssertNil(out)
    }
}
