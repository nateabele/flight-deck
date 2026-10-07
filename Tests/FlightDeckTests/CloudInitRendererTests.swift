import HostKit
import XCTest
@testable import FlightDeck

/// The user-data a cloud machine boots with. The golden files are the reviewed contract; the
/// other cases pin the properties a reviewer would otherwise have to re-derive from them: on AWS
/// the TTL is armed before anything that can fail, the metadata endpoint (whose user-data holds
/// the host's long-term PSK) is closed to workloads on every boot, the user manager is up before
/// the installer needs it, and nothing user-controlled can break out of its quoting.
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

    /// Ruling 1, AWS: a failed install must still die, and a reboot must not disarm it. A pending
    /// `shutdown -h +N` dies with the reboot, so the TTL is an absolute, persistent systemd timer,
    /// enabled before the install; the preset turns the poweroff into a termination.
    func testAWSTTLIsAPersistentTimerArmedBeforeTheInstall() throws {
        let y = try CloudInitRenderer.render(payload, base)
        XCTAssertTrue(y.contains("OnCalendar=2027-01-15 12:00:00 UTC"))
        XCTAssertTrue(y.contains("Persistent=true"))
        XCTAssertTrue(y.contains("ExecStart=/usr/bin/systemctl poweroff"))
        XCTAssertTrue(y.contains("WantedBy=timers.target"))
        XCTAssertFalse(y.contains("shutdown -h"))
        XCTAssertFalse(y.contains("shutdown, -h"))
        let runcmd = line(y, "runcmd:")
        let arm = line(y, "[ systemctl, enable, --now, flightdeck-ttl.timer ]")
        XCTAssertEqual(arm, runcmd + 1, "the TTL is the first runcmd step")
        XCTAssertLessThan(arm, line(y, "hostd-install.sh"))
    }

    /// Ruling 1 revised, GCP: a guest poweroff only STOPS a GCE VM, which keeps billing its disk
    /// and stops `max_run_duration` counting. The deadline falls before that expiry, so a timer
    /// would fire first and turn the preset's guaranteed DELETE into a leak: GCP gets none.
    func testGCPRendersNoTTLTimer() throws {
        let y = try CloudInitRenderer.render(payload, tailnetGCP)
        XCTAssertFalse(y.contains("flightdeck-ttl"))
        XCTAssertFalse(y.contains("OnCalendar"))
        XCTAssertFalse(y.contains("poweroff"))
        XCTAssertFalse(y.contains("shutdown"))
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

    /// Ruling 2: the enrollment secret is the controller's long-term PSK for this host, and
    /// user-data stays readable from the metadata service for the machine's whole life, so only
    /// root may reach that endpoint, from the first boot and on every reboot. iptables state does
    /// not survive a reboot and runcmd runs once per instance, so the rules live in bootcmd,
    /// which runs on every boot. Each tolerates its address family being absent. GCP needs only
    /// the IPv4 rule: `metadata.google.internal` is the same address.
    func testMetadataEndpointIsClosedToNonRootOnEveryBoot() throws {
        func rule(_ tool: String, _ address: String) -> String {
            #"  - [ sh, -c, "\#(tool) -A OUTPUT -d \#(address) -m owner ! --uid-owner 0 -j REJECT || true" ]"#
        }
        let v4 = rule("iptables", "169.254.169.254")
        let v6 = rule("ip6tables", "fd00:ec2::254")
        let gcpName = rule("iptables", "metadata.google.internal")

        for (o, present, absent) in [(base, [v4, v6], [gcpName]), (tailnetGCP, [v4], [v6, gcpName])] {
            let y = try CloudInitRenderer.render(payload, o)
            let lines = y.components(separatedBy: "\n")
            let bootcmd = line(y, "bootcmd:")
            let nextSection = line(y, "write_files:")
            XCTAssertGreaterThanOrEqual(bootcmd, 0, o.cloud)
            for r in present {
                let at = lines.firstIndex(of: r) ?? -1
                XCTAssertTrue(at > bootcmd && at < nextSection, "\(r) not under bootcmd on \(o.cloud)")
                XCTAssertEqual(lines.filter { $0 == r }.count, 1, "\(r) rendered more than once on \(o.cloud)")
            }
            for r in absent { XCTAssertFalse(lines.contains(r), "\(r) on \(o.cloud)") }
            // Not only in runcmd: no copy there at all.
            let runcmd = line(y, "runcmd:")
            XCTAssertFalse(lines[runcmd...].contains { $0.contains("tables") }, o.cloud)
        }
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

    /// `loginctl enable-linger` returns before `user@UID` is up, and `su -` from cloud-final may
    /// carry no `XDG_RUNTIME_DIR`, so the installer's `systemctl --user` could find no manager.
    /// The manager is started (and waited for) first, and both user steps name its runtime dir.
    func testUserManagerIsUpBeforeTheInstallerNeedsIt() throws {
        for o in [base, tailnetGCP] {
            let y = try CloudInitRenderer.render(payload, o)
            let linger = line(y, "[ loginctl, enable-linger, flightdeck ]")
            let start = line(y, #"[ sh, -c, "systemctl start user@$(id -u flightdeck).service" ]"#)
            let install = line(y, "hostd-install.sh")
            let enroll = line(y, "flightdeck-hostd enroll")
            XCTAssertLessThan(linger, start, o.cloud)
            XCTAssertLessThan(start, install, o.cloud)
            XCTAssertLessThan(install, enroll, o.cloud)
            let lines = y.components(separatedBy: "\n")
            for i in [install, enroll] where i >= 0 {
                XCTAssertTrue(lines[i].contains(#""-c", "export XDG_RUNTIME_DIR=/run/user/$(id -u flightdeck); "#),
                              "\(lines[i]) on \(o.cloud)")
            }
        }
    }

    /// `JSONEncoder` leaves U+0085 and U+2028/9 raw, and YAML reads them as line breaks: a
    /// controller name could end the block scalar and inject keys into root's user-data. The
    /// line is forced to pure ASCII, and still decodes to the same name.
    func testControllerNameCannotLeaveTheEnrollLine() throws {
        let name = "a\u{0085}b\u{2028}c\u{2029}d\u{1F600}"
        let p = EnrollmentPayload(version: 1, slot: payload.slot, secretHex: payload.secretHex, controllerName: name,
                                  idleSeconds: 1800, issuedAt: payload.issuedAt)
        let y = try CloudInitRenderer.render(p, base)
        XCTAssertTrue(y.unicodeScalars.allSatisfy(\.isASCII), "the whole render is ASCII")
        let lines = y.components(separatedBy: "\n")
        let path = line(y, "path: /run/flightdeck/enroll.json")
        guard path >= 0, path + 4 < lines.count else { return }
        XCTAssertEqual(lines[path + 5], "runcmd:", "the JSON stays one line inside its block")
        let json = lines[path + 4].trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(json.contains(#"\ud83d\ude00"#), "astral scalars become a surrogate pair")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(EnrollmentPayload.self, from: Data(json.utf8)).controllerName, name)
    }

    func testRejectsControlCharactersInControllerName() {
        for name in ["a\nb", "a\rb", "a\u{0}b", "a\tb", "a\u{7F}b"] {
            let p = EnrollmentPayload(version: 1, slot: payload.slot, secretHex: payload.secretHex, controllerName: name,
                                      idleSeconds: 1800, issuedAt: payload.issuedAt)
            XCTAssertThrowsError(try CloudInitRenderer.render(p, base), name.debugDescription)
        }
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
