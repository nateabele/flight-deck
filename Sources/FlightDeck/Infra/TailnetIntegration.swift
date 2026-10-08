import Foundation
import HostKit
import Security

// Tailnet mode (spec §6.1): a cloud machine joins this Mac's tailnet with a single-use,
// preauthorized, ephemeral auth key tagged `tag:flightdeck-cloud`, and its `fd_address` is the
// tailnet IP the Tailscale API reports once it joins. Everything here is optional — a Mac with
// no Tailscale, or no OAuth client for its tailnet, falls back to public mode (§6.2).

/// What this Mac's own `tailscale` says. All false/nil when there is no CLI or it fails.
struct LocalTailnet: Equatable, Sendable {
    let running: Bool
    let tailnet: String?
    let selfIP: String?
    let lockEnabled: Bool
    /// This node's Tailnet Lock key is one of the trusted keys, so it can sign new nodes.
    let lockSigner: Bool

    static let absent = LocalTailnet(running: false, tailnet: nil, selfIP: nil, lockEnabled: false, lockSigner: false)
}

/// The OAuth client the user created on Tailscale's admin page, stored in the Keychain only.
/// `tailnet` is recorded at setup so a client for one tailnet is never used to join another.
struct TailscaleOAuthClient: Codable, Equatable, Sendable {
    let id: String
    let secret: String
    let tailnet: String
}

/// Every way Swift prints a value — interpolation, `print`, `debugPrint`, `dump`, an array of
/// them, an assertion message — goes through one of these, so the secret never reaches a log.
extension TailscaleOAuthClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "TailscaleOAuthClient(id: \(id), secret: <redacted>, tailnet: \(tailnet))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["id": id, "secret": "<redacted>", "tailnet": tailnet]) }
}

enum TailnetMode: Equatable, Sendable {
    case available(TailscaleOAuthClient)
    case notRunning
    /// Running, but no OAuth client: `infra up` uses public mode and points at setup.
    case notConfigured(tailnet: String)
    /// Refused outright: minting a key with the other tailnet's client would put the machine
    /// on a tailnet this Mac cannot reach.
    case mismatch(local: String, client: String)
}

/// A cloud machine's node as the Tailscale API lists it: its IPv4 once it has one, and the key
/// `tailscale lock sign` takes under Tailnet Lock.
struct TailnetNode: Equatable, Sendable {
    let address: String?
    let nodeKey: String?
}

enum TailnetError: Error, Equatable {
    case unexpectedResponse(String)
    case lockSignFailed
    /// The policy changed since it was read (a 412 on the `If-Match` write): re-fetch and
    /// re-diff rather than overwrite someone else's edit.
    case policyChanged
}

protocol TailnetSecretStoring: Sendable {
    func load() -> TailscaleOAuthClient?
    func save(_ c: TailscaleOAuthClient) throws
    func clear()
}

final class TailnetIntegration: @unchecked Sendable {
    private let cli: URL?
    private let http: HTTPFetching
    private let secrets: TailnetSecretStoring

    private static let api = URL(string: "https://api.tailscale.com/api/v2/")!

    init(cli: URL?, http: HTTPFetching, secrets: TailnetSecretStoring) {
        self.cli = cli; self.http = http; self.secrets = secrets
    }

    /// The first `tailscale` this Mac has, by `TailscaleCLI`'s own search order.
    static func defaultCLI() -> URL? {
        TailscaleCLI.candidates().first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    // MARK: Local CLI

    func local() async -> LocalTailnet {
        guard let cli, let data = TailscaleCLI.run(cli.path, ["status", "--json"], timeout: 2) else { return .absent }
        struct Status: Decodable {
            struct Tailnet: Decodable { let Name: String? }
            struct Node: Decodable { let TailscaleIPs: [String]? }
            let BackendState: String?
            let CurrentTailnet: Tailnet?
            let Self_: Node?
            enum CodingKeys: String, CodingKey { case BackendState, CurrentTailnet, Self_ = "Self" }
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return .absent }
        let lock = lockStatus(cli)
        return LocalTailnet(running: status.BackendState == "Running", tailnet: status.CurrentTailnet?.Name,
                            selfIP: status.Self_?.TailscaleIPs?.first,
                            lockEnabled: lock?.enabled ?? false, lockSigner: lock?.signer ?? false)
    }

    /// `tailscale lock status --json`: `PublicKey` is this node's lock key; it can sign when
    /// that key is among `TrustedKeys`. Nil (no lock) when the CLI or its output fails.
    private func lockStatus(_ cli: URL) -> (enabled: Bool, signer: Bool)? {
        struct Lock: Decodable {
            struct Key: Decodable { let Key: String }
            let Enabled: Bool?
            let PublicKey: String?
            let TrustedKeys: [Key]?
        }
        guard let data = TailscaleCLI.run(cli.path, ["lock", "status", "--json"], timeout: 2),
              let lock = try? JSONDecoder().decode(Lock.self, from: data) else { return nil }
        let signer = lock.PublicKey.map { key in lock.TrustedKeys?.contains { $0.Key == key } ?? false } ?? false
        return (lock.Enabled ?? false, signer)
    }

    /// Stores the OAuth client the user created during setup (spec §9), in the Keychain only.
    func saveClient(_ client: TailscaleOAuthClient) throws { try secrets.save(client) }

    func mode() async -> TailnetMode {
        let local = await local()
        guard local.running, let tailnet = local.tailnet else { return .notRunning }
        guard let client = secrets.load() else { return .notConfigured(tailnet: tailnet) }
        // Tailnet names are DNS names, so case is not a difference.
        guard client.tailnet.lowercased() == tailnet.lowercased() else {
            return .mismatch(local: tailnet, client: client.tailnet)
        }
        return .available(client)
    }

    /// Signs a new node under Tailnet Lock when this Mac can. False when lock is off or this
    /// Mac is not a signer — the caller reports which device must sign; a failed sign throws,
    /// so it never reads as done.
    func signIfSigner(nodeKey: String) async throws -> Bool {
        let local = await local()
        guard let cli, local.lockEnabled, local.lockSigner else { return false }
        guard TailscaleCLI.run(cli.path, ["lock", "sign", nodeKey], timeout: 10) != nil else {
            throw TailnetError.lockSignFailed
        }
        return true
    }

    // MARK: Tailscale API

    /// Single-use, preauthorized, ephemeral and tagged: a key that leaks after the machine
    /// joined can join nothing, and the node leaves the tailnet on its own once it is gone.
    func mintAuthKey(client: TailscaleOAuthClient, tag: String, expiry: HostKit.Duration) async throws -> String {
        let create: [String: Any] = ["reusable": false, "ephemeral": true, "preauthorized": true, "tags": [tag]]
        let body = try JSONSerialization.data(withJSONObject: [
            "capabilities": ["devices": ["create": create]], "expirySeconds": expiry.seconds])
        var headers = try await authorization(client)
        headers["Content-Type"] = "application/json"
        let (data, _) = try await http.post(Self.api.appendingPathComponent("tailnet/-/keys"), headers: headers, body: body)
        struct Key: Decodable { let key: String }
        guard let key = try? JSONDecoder().decode(Key.self, from: data).key else {
            throw TailnetError.unexpectedResponse("keys")
        }
        return key
    }

    /// The node's tailnet IPv4, or nil while it has not joined.
    func nodeAddress(client: TailscaleOAuthClient, hostname: String) async throws -> String? {
        try await cloudNode(client: client, hostname: hostname)?.address
    }

    /// The cloud machine's node, or nil while it has not joined. Only a `cloudTag` node counts,
    /// as for `deleteNode`: one of the user's own devices that happens to share the hostname
    /// must never become a host's address. When several match, the newest wins: an older one
    /// is a previous machine's leftover node.
    func cloudNode(client: TailscaleOAuthClient, hostname: String) async throws -> TailnetNode? {
        let node = try await devices(client, hostname: hostname)
            .filter { $0.tags?.contains(Self.cloudTag) == true }
            .max { ($0.created ?? "") < ($1.created ?? "") }
        return node.map { TailnetNode(address: $0.addresses?.first { $0.contains(".") }, nodeKey: $0.nodeKey) }
    }

    /// The tag every cloud machine joins with (spec §6.1).
    static let cloudTag = "tag:flightdeck-cloud"

    /// Every cloud node with this hostname, so a destroyed machine leaves nothing behind — and
    /// only cloud nodes: one of the user's own devices that happens to share the hostname is
    /// untagged (or tagged otherwise) and must never be removed from their tailnet.
    func deleteNode(client: TailscaleOAuthClient, hostname: String) async throws {
        let headers = try await authorization(client)
        for node in try await devices(client, hostname: hostname, headers: headers)
        where node.tags?.contains(Self.cloudTag) == true {
            try await http.delete(Self.api.appendingPathComponent("device/\(node.id)"), headers: headers)
        }
    }

    private struct Device: Decodable {
        let id: String
        let hostname: String
        let addresses: [String]?
        let created: String?
        let nodeKey: String?
        let tags: [String]?
    }

    private func devices(_ client: TailscaleOAuthClient, hostname: String,
                         headers given: [String: String]? = nil) async throws -> [Device] {
        let headers: [String: String]
        if let given { headers = given } else { headers = try await authorization(client) }
        let data = try await http.get(Self.api.appendingPathComponent("tailnet/-/devices"), headers: headers).0
        struct Devices: Decodable { let devices: [Device] }
        guard let all = try? JSONDecoder().decode(Devices.self, from: data).devices else {
            throw TailnetError.unexpectedResponse("devices")
        }
        return all.filter { $0.hostname == hostname }
    }

    // MARK: Policy (setup only)

    // The policy is read and written with the API access token the user pastes during setup
    // (spec §9), never the OAuth client: that client is scoped to minting keys and managing
    // devices, and a policy write needs a broader grant than it should ever hold.

    /// The policy as HuJSON, comments and all, with the `ETag` `savePolicy` must quote.
    func fetchPolicy(token: String) async throws -> (hujson: String, etag: String) {
        let (data, headers) = try await http.get(Self.api.appendingPathComponent("tailnet/-/acl"),
                                                 headers: ["Authorization": "Bearer \(token)", "Accept": "application/hujson"])
        // Header names are case-insensitive, and `HTTPURLResponse` does not promise a spelling.
        guard let etag = headers.first(where: { $0.key.caseInsensitiveCompare("ETag") == .orderedSame })?.value,
              let hujson = String(data: data, encoding: .utf8) else {
            throw TailnetError.unexpectedResponse("acl")
        }
        return (hujson, etag)
    }

    /// Writes the policy only if it is still the one `etag` names; otherwise `policyChanged`,
    /// so setup re-fetches and shows a fresh diff instead of overwriting someone's edit.
    func savePolicy(token: String, hujson: String, etag: String) async throws {
        do {
            _ = try await http.post(Self.api.appendingPathComponent("tailnet/-/acl"),
                                    headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/hujson",
                                              "If-Match": etag],
                                    body: Data(hujson.utf8))
        } catch let error as HTTPStatusError where error.status == 412 {
            throw TailnetError.policyChanged
        }
    }

    /// A fresh OAuth access token per call: they live an hour and each operation here is a
    /// handful of requests, so a cache would only add a stale-token failure.
    private func authorization(_ client: TailscaleOAuthClient) async throws -> [String: String] {
        let form = "client_id=\(Self.formEncoded(client.id))&client_secret=\(Self.formEncoded(client.secret))"
        let (data, _) = try await http.post(Self.api.appendingPathComponent("oauth/token"),
                                            headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                            body: Data(form.utf8))
        struct Token: Decodable { let access_token: String }
        guard let token = try? JSONDecoder().decode(Token.self, from: data).access_token else {
            throw TailnetError.unexpectedResponse("oauth/token")
        }
        return ["Authorization": "Bearer \(token)"]
    }

    private static let formSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formSafe) ?? value
    }
}

/// The OAuth client as one generic-password item: service `dev.flightdeck.tailscale-oauth`,
/// with `KeychainHostSecretStore`'s attributes and update-then-add shape.
final class KeychainTailnetSecrets: TailnetSecretStoring {
    private let service: String

    /// `service` is a parameter only so a Keychain test can use a throwaway name.
    init(service: String = "dev.flightdeck.tailscale-oauth") {
        self.service = service
    }

    func load() -> TailscaleOAuthClient? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TailscaleOAuthClient.self, from: data)
    }

    func save(_ c: TailscaleOAuthClient) throws {
        let data = try JSONEncoder().encode(c)
        let updated = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw HostSecretStoreError.keychainWriteFailed(status: updated) }
        var attributes = identity
        attributes[kSecValueData as String] = data
        // Never synced: the client can mint keys that join machines to the tailnet.
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw HostSecretStoreError.keychainWriteFailed(status: added) }
    }

    func clear() {
        SecItemDelete(identity as CFDictionary)
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "oauth-client"]
    }
}
