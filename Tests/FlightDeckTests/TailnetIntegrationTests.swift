import XCTest
@testable import FlightDeck

final class TailnetIntegrationTests: XCTestCase {
    func testModeNotRunningWithoutCLI() async {
        let t = TailnetIntegration(cli: nil, http: FakeHTTP(), secrets: MemoryTailnetSecrets())
        let m = await t.mode()
        XCTAssertEqual(m, .notRunning)
    }

    func testModeMismatchRefuses() async throws {
        let cli = try FakeExecutable.make("tailscale", script: #"echo '{"BackendState":"Running","CurrentTailnet":{"Name":"example-tailnet.ts.net"},"Self":{"TailscaleIPs":["100.64.0.2"]}}'"#)
        let secrets = MemoryTailnetSecrets(TailscaleOAuthClient(id: "k", secret: "s", tailnet: "other.ts.net"))
        let m = await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: secrets).mode()
        XCTAssertEqual(m, .mismatch(local: "example-tailnet.ts.net", client: "other.ts.net"))
    }

    func testMintRequestsEphemeralPreauthorizedSingleUseTaggedKey() async throws {
        let http = FakeHTTP(responses: [
            "https://api.tailscale.com/api/v2/oauth/token": #"{"access_token":"tok","expires_in":3600}"#,
            "https://api.tailscale.com/api/v2/tailnet/-/keys": #"{"key":"tskey-auth-EXAMPLE"}"#])
        let t = TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets())
        let key = try await t.mintAuthKey(client: .init(id: "k", secret: "s", tailnet: "example-tailnet.ts.net"), tag: "tag:flightdeck-cloud", expiry: .init(seconds: 900))
        XCTAssertEqual(key, "tskey-auth-EXAMPLE")
        let body = try XCTUnwrap(http.lastBody(for: "https://api.tailscale.com/api/v2/tailnet/-/keys"))
        let caps = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let create = ((caps["capabilities"] as! [String: Any])["devices"] as! [String: Any])["create"] as! [String: Any]
        XCTAssertEqual(create["ephemeral"] as? Bool, true); XCTAssertEqual(create["preauthorized"] as? Bool, true)
        XCTAssertEqual(create["reusable"] as? Bool, false); XCTAssertEqual(create["tags"] as? [String], ["tag:flightdeck-cloud"])
        XCTAssertEqual(caps["expirySeconds"] as? Int, 900)
    }

    // Beyond the brief.

    func testMintAuthenticatesWithTheOAuthClientThenTheBearerToken() async throws {
        let http = FakeHTTP(responses: [
            "https://api.tailscale.com/api/v2/oauth/token": #"{"access_token":"tok","expires_in":3600}"#,
            "https://api.tailscale.com/api/v2/tailnet/-/keys": #"{"key":"tskey-auth-EXAMPLE"}"#])
        let t = TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets())
        _ = try await t.mintAuthKey(client: .init(id: "k&1", secret: "s=2", tailnet: "example-tailnet.ts.net"), tag: "tag:flightdeck-cloud", expiry: .init(seconds: 900))
        let token = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(token.method, "POST")
        XCTAssertEqual(token.headers["Content-Type"], "application/x-www-form-urlencoded")
        // Form-encoded, so a secret holding `&` or `=` cannot split into a second field.
        XCTAssertEqual(String(decoding: try XCTUnwrap(token.body), as: UTF8.self), "client_id=k%261&client_secret=s%3D2")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer tok")
    }

    func testModeAvailableAndNotConfigured() async throws {
        let cli = try FakeExecutable.make("tailscale", script: #"echo '{"BackendState":"Running","CurrentTailnet":{"Name":"example-tailnet.ts.net"},"Self":{"TailscaleIPs":["100.64.0.2"]}}'"#)
        let none = await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).mode()
        XCTAssertEqual(none, .notConfigured(tailnet: "example-tailnet.ts.net"))
        let client = TailscaleOAuthClient(id: "k", secret: "s", tailnet: "example-tailnet.ts.net")
        let some = await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: MemoryTailnetSecrets(client)).mode()
        XCTAssertEqual(some, .available(client))
    }

    func testStoppedBackendIsNotRunning() async throws {
        let cli = try FakeExecutable.make("tailscale", script: #"echo '{"BackendState":"Stopped","CurrentTailnet":{"Name":"example-tailnet.ts.net"}}'"#)
        let local = await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).local()
        XCTAssertFalse(local.running)
        let m = await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).mode()
        XCTAssertEqual(m, .notRunning)
    }

    func testNodeAddressIsTheMatchingDevicesIPv4AndDeleteRemovesOnlyTaggedMatches() async throws {
        let http = FakeHTTP(responses: [
            "https://api.tailscale.com/api/v2/oauth/token": #"{"access_token":"tok"}"#,
            "https://api.tailscale.com/api/v2/tailnet/-/devices": #"""
            {"devices":[
              {"id":"1","hostname":"other","addresses":["100.64.0.9"]},
              {"id":"2","hostname":"fd-cloud-a","addresses":["fd7a:115c:a1e0::5","100.64.0.5"],"tags":["tag:flightdeck-cloud"]},
              {"id":"3","hostname":"fd-cloud-a","addresses":["100.64.0.6"],"tags":["tag:other","tag:flightdeck-cloud"]},
              {"id":"4","hostname":"fd-cloud-a","addresses":["100.64.0.7"]},
              {"id":"5","hostname":"fd-cloud-a","addresses":["100.64.0.8"],"tags":["tag:ci"]}]}
            """#,
            "https://api.tailscale.com/api/v2/device/2": "",
            "https://api.tailscale.com/api/v2/device/3": "",
            "https://api.tailscale.com/api/v2/device/4": "",
            "https://api.tailscale.com/api/v2/device/5": ""])
        let t = TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets())
        let client = TailscaleOAuthClient(id: "k", secret: "s", tailnet: "example-tailnet.ts.net")
        let address = try await t.nodeAddress(client: client, hostname: "fd-cloud-a")
        XCTAssertEqual(address, "100.64.0.5")
        let absent = try await t.nodeAddress(client: client, hostname: "missing")
        XCTAssertNil(absent)
        // Devices 4 and 5 share the hostname but not the tag: someone's own machine, which a
        // destroy must never remove from their tailnet.
        try await t.deleteNode(client: client, hostname: "fd-cloud-a")
        XCTAssertEqual(http.requests.filter { $0.method == "DELETE" }.map(\.url),
                       ["https://api.tailscale.com/api/v2/device/2", "https://api.tailscale.com/api/v2/device/3"])
        XCTAssertTrue(http.requests.filter { $0.method == "DELETE" }.allSatisfy { $0.headers["Authorization"] == "Bearer tok" })
    }

    func testSignsOnlyWhenLockIsOnAndThisMacIsASigner() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        func fake(lock: String) throws -> URL {
            try FakeExecutable.make("tailscale", script: """
            case "$1 $2" in
              "status --json") echo '{"BackendState":"Running","CurrentTailnet":{"Name":"example-tailnet.ts.net"},"Self":{"TailscaleIPs":["100.64.0.2"]}}' ;;
              "lock status") echo '\(lock)' ;;
              "lock sign") \(FakeExecutable.record(to: log)) ;;
              *) exit 1 ;;
            esac
            """)
        }
        let signer = try fake(lock: #"{"Enabled":true,"PublicKey":"tlpub:aa","TrustedKeys":[{"Key":"tlpub:bb"},{"Key":"tlpub:aa"}]}"#)
        let local = await TailnetIntegration(cli: signer, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).local()
        XCTAssertEqual(local, LocalTailnet(running: true, tailnet: "example-tailnet.ts.net", selfIP: "100.64.0.2", lockEnabled: true, lockSigner: true))
        let signed = try await TailnetIntegration(cli: signer, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).signIfSigner(nodeKey: "nodekey:abc")
        XCTAssertTrue(signed)
        XCTAssertEqual(FakeExecutable.calls(log), ["lock sign nodekey:abc"])

        let notSigner = try fake(lock: #"{"Enabled":true,"PublicKey":"tlpub:aa","TrustedKeys":[{"Key":"tlpub:bb"}]}"#)
        let skipped = try await TailnetIntegration(cli: notSigner, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).signIfSigner(nodeKey: "nodekey:abc")
        XCTAssertFalse(skipped)
        let off = try fake(lock: #"{"Enabled":false,"PublicKey":"tlpub:aa","TrustedKeys":[{"Key":"tlpub:aa"}]}"#)
        let unlocked = try await TailnetIntegration(cli: off, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).signIfSigner(nodeKey: "nodekey:abc")
        XCTAssertFalse(unlocked)
        XCTAssertEqual(FakeExecutable.calls(log).count, 1)
    }

    func testFailedSignThrows() async throws {
        let cli = try FakeExecutable.make("tailscale", script: """
        case "$1 $2" in
          "status --json") echo '{"BackendState":"Running","CurrentTailnet":{"Name":"example-tailnet.ts.net"}}' ;;
          "lock status") echo '{"Enabled":true,"PublicKey":"tlpub:aa","TrustedKeys":[{"Key":"tlpub:aa"}]}' ;;
          *) exit 1 ;;
        esac
        """)
        do {
            _ = try await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: MemoryTailnetSecrets()).signIfSigner(nodeKey: "nodekey:abc")
            XCTFail("a failed `tailscale lock sign` must not read as signed")
        } catch {}
    }

    // MARK: Policy round trip (setup, with the user's API access token)

    private let acl = "https://api.tailscale.com/api/v2/tailnet/-/acl"

    func testFetchPolicyReturnsTheBodyAndTheETag() async throws {
        let http = FakeHTTP(responses: [acl: "// policy\n{}\n"], responseHeaders: [acl: ["Etag": "\"e1\""]])
        let t = TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets())
        let policy = try await t.fetchPolicy(token: "tskey-api-EXAMPLE")
        XCTAssertEqual(policy.hujson, "// policy\n{}\n")
        XCTAssertEqual(policy.etag, "\"e1\"")
        XCTAssertEqual(http.requests.map(\.method), ["GET"], "the API token is used as is, never traded for an OAuth one")
        XCTAssertEqual(http.requests.first?.headers["Accept"], "application/hujson")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer tskey-api-EXAMPLE")
    }

    func testFetchPolicyWithoutAnETagThrows() async {
        let http = FakeHTTP(responses: [acl: "{}"])
        do {
            _ = try await TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets()).fetchPolicy(token: "t")
            XCTFail("a policy with no ETag cannot be written back safely")
        } catch {}
    }

    func testSavePolicySendsIfMatchAndTheBody() async throws {
        let http = FakeHTTP(responses: [acl: "{}"])
        let t = TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets())
        try await t.savePolicy(token: "tskey-api-EXAMPLE", hujson: "// mine\n{}\n", etag: "\"e1\"")
        let post = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(post.method, "POST"); XCTAssertEqual(post.url, acl)
        XCTAssertEqual(post.headers["If-Match"], "\"e1\"")
        XCTAssertEqual(post.headers["Content-Type"], "application/hujson")
        XCTAssertEqual(post.headers["Authorization"], "Bearer tskey-api-EXAMPLE")
        XCTAssertEqual(post.body, Data("// mine\n{}\n".utf8))
    }

    func testSavePolicyOnAChangedPolicyIsPolicyChanged() async {
        let http = FakeHTTP(statuses: [acl: 412])
        do {
            try await TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets()).savePolicy(token: "t", hujson: "{}", etag: "\"old\"")
            XCTFail("a stale ETag must not read as saved")
        } catch {
            XCTAssertEqual(error as? TailnetError, .policyChanged)
        }
        let forbidden = FakeHTTP(statuses: [acl: 403])
        do {
            try await TailnetIntegration(cli: nil, http: forbidden, secrets: MemoryTailnetSecrets()).savePolicy(token: "t", hujson: "{}", etag: "\"e\"")
            XCTFail("a 403 must throw")
        } catch {
            XCTAssertEqual(error as? HTTPStatusError, HTTPStatusError(status: 403), "only a 412 means re-fetch and re-diff")
        }
    }

    func testOAuthClientNeverPrintsItsSecret() {
        let client = TailscaleOAuthClient(id: "k-EXAMPLE", secret: "tskey-client-SECRET", tailnet: "example-tailnet.ts.net")
        var dumped = ""
        dump(client, to: &dumped)
        for text in ["\(client)", String(describing: client), String(reflecting: client), dumped, "\([client])"] {
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertTrue(text.contains("k-EXAMPLE"), text)
        }
    }
}
