import Foundation
import Security

/// Where the phone keeps `PairedMac`. `AnyObject`-bound so a reference to the store can be
/// shared and mutated in place rather than copied.
public protocol PairedMacStoring: AnyObject {
    func load() -> PairedMac?
    func save(_ mac: PairedMac)
    func clear()
}

/// A store with no persistence, for tests and previews.
public final class InMemoryPairedMacStore: PairedMacStoring {
    private var stored: PairedMac?

    public init() {}

    public func load() -> PairedMac? { stored }

    public func save(_ mac: PairedMac) { stored = mac }

    public func clear() { stored = nil }
}

/// One Keychain item holding the whole pairing as JSON.
///
/// One item rather than a secret here and the metadata there: two stores can disagree, and
/// a phone holding a key with no endpoints — or endpoints with no key — is a state with no
/// recovery short of re-pairing.
public final class KeychainPairedMacStore: PairedMacStoring {
    private static let service = "dev.flightdeck.pairedMac"
    private static let account = "primary"

    public init() {}

    /// Exposed so the two attributes that matter are assertable without a keychain — see
    /// `PairedMacStoreTests`.
    public static func attributes(for data: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never synced. An iCloud-synced pairing key would silently grant access to a
            // device the user never pointed at the QR, which is the one thing the whole
            // trust-on-first-use story rests on not happening.
            kSecAttrSynchronizable as String: false,
            // Survives a reboot without the phone being unlocked first (so a reconnect can
            // happen in the background) but never leaves this hardware in a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    /// Delete-then-add rather than `SecItemUpdate`. An update against an item that is not
    /// there fails silently, leaving the phone believing it saved a pairing it did not — and
    /// the symptom is a relaunch that has forgotten the Mac for no visible reason.
    ///
    /// Both possible failures here — an encode that cannot fail in practice (`PairedMac` is
    /// all `Codable` primitives plus the manual `Body` above) and a `SecItemAdd` that can
    /// fail for real (entitlement misconfiguration, keychain access group mismatch) — are
    /// asserted rather than silently swallowed. The signature stays `Void`: the caller (the
    /// pairing flow, Task 10) cannot do anything more useful with a thrown error than the
    /// developer can with a DEBUG trap, and swallowing either would leave the phone believing
    /// it saved a pairing it did not, which is exactly the failure mode `save` exists to rule
    /// out. `assertionFailure` traps in DEBUG and is a no-op in release, where the user
    /// simply re-pairs.
    public func save(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else {
            assertionFailure("PairedMac failed to encode")
            return
        }
        SecItemDelete(Self.identityQuery as CFDictionary)
        let status = SecItemAdd(Self.attributes(for: data) as CFDictionary, nil)
        if status != errSecSuccess {
            assertionFailure("SecItemAdd failed with status \(status)")
        }
    }

    public func load() -> PairedMac? {
        var query = Self.identityQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    public func clear() {
        SecItemDelete(Self.identityQuery as CFDictionary)
    }

    /// The subset that identifies the item, for lookup and deletion. Deliberately without
    /// `kSecAttrAccessible`/`kSecAttrSynchronizable`: those are attributes of the stored
    /// item, and including them in a *query* narrows the match in ways that make a delete
    /// silently miss.
    private static var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
