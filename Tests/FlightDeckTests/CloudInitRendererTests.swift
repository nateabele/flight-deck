import HostKit
import XCTest
@testable import FlightDeck

/// The user-data a cloud machine boots with. The golden files are the reviewed contract; the
/// other cases pin the properties a reviewer would otherwise have to re-derive from them: the
/// TTL is armed before anything that can fail, the metadata endpoint is closed to workloads once
/// the PSK in user-data is spent, and nothing user-controlled can break out of its quoting.
final class CloudInitRendererTests: XCTestCase {
    private final class Token {}

    let payload = EnrollmentPayload(version: 1, slot: UUID(uuidString: "6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00")!,
        secretHex: String(repeating: "5a", count: 32), controllerName: "controller", idleSeconds: 1800,
        issuedAt: Date(timeIntervalSince1970: 1_800_000_000))
    // Four hours after `issuedAt`: 2027-01-15 12:00:00 UTC.
    let base = CloudInitOptions(installerBaseURL: "https://example.invalid/hostd", installerSHA256: String(repeating: "0", count: 64),
                                deadline: Date(timeIntervalSince1970: 1_800_014_400), cloud: "aws",
                                tailscaleAuthKey: nil, tailscaleHostname: nil)

    private func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Token.self).url(forResource: name, withExtension: "yaml",
                                                            subdirectory: "Fixtures/cloud-init"),
                                "missing fixture \(name).yaml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var tailnetGCP: CloudInitOptions {
        var o = base
        o.cloud = "gcp"; o.tailscaleAuthKey = "tskey-auth-EXAMPLE"; o.tailscaleHostname = "fd-gpu"
        return o
    }

    /// The line of `yaml` containing `needle`; fails the test when there is none.
    private func line(_ yaml: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let lines = yaml.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains(needle) }) else {
            XCTFail("no line contains \(needle)", file: file, line: line)
            return -1
        }
        return index
    }

    func testPublicAWSMatchesGolden() throws {
        XCTAssertEqual(try CloudInitRenderer.render(payload, base), try golden("public-aws"))
    }

    func testTailnetGCPMatchesGolden() throws {
        XCTAssertEqual(try CloudInitRenderer.render(payload, tailnetGCP), try golden("tailnet-gcp"))
    }

    func testInvariants() throws {
        let y = try CloudInitRenderer.render(payload, base)
        XCTAssertTrue(y.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(y.contains("/run/flightdeck/enroll.json")); XCTAssertTrue(y.contains("permissions: '0600'"))
        XCTAssertTrue(y.contains("--no-pair")); XCTAssertTrue(y.contains("flightdeck-hostd enroll --file /run/flightdeck/enroll.json"))
        XCTAssertFalse(y.contains("tailscale"))
    }

    /// The enroll file's secret, round-tripped through the same decoder hostd's `enroll` uses.
    func testEnrollFileDecodesBackToThePayload() throws {
        let y = try CloudInitRenderer.render(payload, base)
        let lines = y.components(separatedBy: "\n")
        let path = line(y, "path: /run/flightdeck/enroll.json")
        guard path >= 0, path + 4 < lines.count else { return }
        let json = lines[path + 4].trimmingCharacters(in: .whitespaces)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(EnrollmentPayload.self, from: Data(json.utf8)), payload)
    }

    /// Ruling 1: a failed install must still die, and a reboot must not disarm it. A pending
    /// `shutdown -h +N` dies with the reboot, so the TTL is an absolute, persistent systemd timer,
    /// enabled before the install, and armed on GCP too as a backstop to `max_run_duration`.
    func testTTLIsAPersistentTimerArmedBeforeTheInstall() throws {
        for o in [base, tailnetGCP] {
            let y = try CloudInitRenderer.render(payload, o)
            XCTAssertTrue(y.contains("OnCalendar=2027-01-15 12:00:00 UTC"), o.cloud)
            XCTAssertTrue(y.contains("Persistent=true"), o.cloud)
            XCTAssertTrue(y.contains("ExecStart=/usr/bin/systemctl poweroff"), o.cloud)
            XCTAssertTrue(y.contains("WantedBy=timers.target"), o.cloud)
            XCTAssertFalse(y.contains("shutdown -h"), o.cloud)
            XCTAssertFalse(y.contains("shutdown, -h"), o.cloud)
            let runcmd = line(y, "runcmd:")
            let arm = line(y, "[ systemctl, enable, --now, flightdeck-ttl.timer ]")
            XCTAssertEqual(arm, runcmd + 1, "the TTL is the first runcmd step on \(o.cloud)")
            XCTAssertLessThan(arm, line(y, "hostd-install.sh"), o.cloud)
        }
    }

    func testDeadlineIsRenderedInUTCWholeSeconds() throws {
        var o = base
        o.deadline = Date(timeIntervalSince1970: 1_800_014_400.75)
        XCTAssertTrue(try CloudInitRenderer.render(payload, o).contains("OnCalendar=2027-01-15 12:00:00 UTC"))
    }

    func testRejectsADeadlineNotAfterIssue() {
        var o = base
        o.deadline = payload.issuedAt
        XCTAssertThrowsError(try CloudInitRenderer.render(payload, o))
    }

    /// Ruling 2: user-data stays readable from the metadata service for the machine's life, so
    /// once the PSK in it is spent, only root may reach that endpoint. On GCP the name is blocked
    /// too, which is the same address.
    func testMetadataEndpointIsClosedToNonRootAfterEnroll() throws {
        let rule = #"[ iptables, -A, OUTPUT, -d, 169.254.169.254, -m, owner, "!", --uid-owner, "0", -j, REJECT ]"#
        let gcpRule = #"[ iptables, -A, OUTPUT, -d, metadata.google.internal, -m, owner, "!", --uid-owner, "0", -j, REJECT ]"#

        let aws = try CloudInitRenderer.render(payload, base)
        XCTAssertGreaterThan(line(aws, rule), line(aws, "flightdeck-hostd enroll"))
        XCTAssertFalse(aws.contains("metadata.google.internal"))

        let gcp = try CloudInitRenderer.render(payload, tailnetGCP)
        XCTAssertGreaterThan(line(gcp, rule), line(gcp, "flightdeck-hostd enroll"))
        XCTAssertGreaterThan(line(gcp, gcpRule), line(gcp, "flightdeck-hostd enroll"))
    }

    /// Ruling 3: a failed enroll must not stop the steps after it. cloud-init's runcmd script
    /// carries on past a failing entry, so the enroll is its own entry and is never chained.
    func testEnrollIsItsOwnUnchainedStep() throws {
        let y = try CloudInitRenderer.render(payload, tailnetGCP)
        let lines = y.components(separatedBy: "\n")
        let index = line(y, "flightdeck-hostd enroll")
        guard index >= 0 else { return }
        let enroll = lines[index]
        XCTAssertTrue(enroll.hasPrefix("  - ["))
        XCTAssertFalse(enroll.contains("&&"))
        XCTAssertFalse(enroll.contains("set -e"))
        XCTAssertGreaterThan(line(y, "tailscale, up"), line(y, "flightdeck-hostd enroll"))
    }

    /// `enroll` deletes the spent file, which needs write access to its directory, not just the
    /// file: both are handed to the user hostd runs as.
    func testEnrollUserOwnsTheFileAndItsDirectory() throws {
        XCTAssertTrue(try CloudInitRenderer.render(payload, base)
            .contains(#"[ chown, "flightdeck:flightdeck", /run/flightdeck, /run/flightdeck/enroll.json ]"#))
    }

    func testRejectsUnsafeValues() {
        var o = base; o.tailscaleHostname = "x; rm -rf /"
        o.tailscaleAuthKey = "k"
        XCTAssertThrowsError(try CloudInitRenderer.render(payload, o))
    }

    func testRejectsEachUnsafeField() {
        let cases: [(String, (inout CloudInitOptions) -> Void)] = [
            ("auth key with a quote", { $0.tailscaleAuthKey = "k\""; $0.tailscaleHostname = "fd-gpu" }),
            ("uppercase hostname", { $0.tailscaleAuthKey = "k"; $0.tailscaleHostname = "FD-GPU" }),
            ("64-char hostname", { $0.tailscaleAuthKey = "k"; $0.tailscaleHostname = String(repeating: "a", count: 64) }),
            ("key without hostname", { $0.tailscaleAuthKey = "k" }),
            ("hostname without key", { $0.tailscaleHostname = "fd-gpu" }),
            ("http installer", { $0.installerBaseURL = "http://example.invalid/hostd" }),
            ("installer with a quote", { $0.installerBaseURL = "https://example.invalid/\"; reboot" }),
            ("installer with a space", { $0.installerBaseURL = "https://example.invalid/a b" }),
            ("short sha", { $0.installerSHA256 = String(repeating: "0", count: 63) }),
            ("non-hex sha", { $0.installerSHA256 = String(repeating: "g", count: 64) }),
            ("unknown cloud", { $0.cloud = "azure" }),
        ]
        for (name, mutate) in cases {
            var o = base
            mutate(&o)
            XCTAssertThrowsError(try CloudInitRenderer.render(payload, o), name)
        }
    }

    func testAcceptsTheMaximalHostnameAndATrailingSlash() throws {
        var o = tailnetGCP
        o.tailscaleHostname = String(repeating: "a", count: 63)
        XCTAssertNoThrow(try CloudInitRenderer.render(payload, o))
        o = base
        o.installerBaseURL = "https://example.invalid/hostd/"
        XCTAssertEqual(try CloudInitRenderer.render(payload, o), try CloudInitRenderer.render(payload, base))
    }
}
