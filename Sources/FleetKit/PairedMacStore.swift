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

    /// Update in place, inserting only when there is nothing to update.
    ///
    /// Deliberately NOT delete-then-add, which is the more obvious shape and was the first
    /// one written here. That shape leaves a window in which no pairing exists on disk, and
    /// the connector persists `lastSeq` through this method on every applied frame — so the
    /// window would not be a rare race but a routine one, entered thousands of times a
    /// session. A process killed inside it loses the pairing outright and the user has to
    /// re-pair, with nothing on screen explaining why. `SecItemUpdate` has no such window.
    ///
    /// The usual argument for the delete shape — that an update against a missing item fails
    /// silently — does not apply, because every status here is checked. `errSecItemNotFound`
    /// is the expected first-save case and falls through to the insert; anything else traps.
    ///
    /// Both failure paths assert rather than swallow: an encode that cannot fail in practice
    /// (`PairedMac` is `Codable` primitives plus the manual `Body` above) and a keychain write
    /// that can fail for real (entitlement misconfiguration, access-group mismatch). The
    /// signature stays `Void` because the caller cannot do anything more useful with an error
    /// than the developer can with a DEBUG trap. Note what that does and does not buy:
    /// `assertionFailure` is a no-op in release, so a release build still cannot tell the user
    /// the write failed. Surfacing that in the pairing UI is a separate decision, not
    /// something this method can do alone.
    public func save(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else {
            assertionFailure("PairedMac failed to encode")
            return
        }
        // Only the payload changes. The two attributes that keep the secret on one device
        // were set at insert and are deliberately not re-specified here.
        let updated = SecItemUpdate(
            Self.identityQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            assertionFailure("SecItemUpdate failed with status \(updated)")
            return
        }
        let added = SecItemAdd(Self.attributes(for: data) as CFDictionary, nil)
        if added != errSecSuccess {
            assertionFailure("SecItemAdd failed with status \(added)")
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

    /// The subset that identifies the item, for lookup, update and deletion. Deliberately
    /// without `kSecAttrSynchronizable` and `kSecAttrAccessible`, though for different
    /// reasons and only the first is load-bearing: `kSecAttrSynchronizable` genuinely
    /// narrows a query — its query default already means "non-synchronizable", which is what
    /// was stored, and spelling it wrongly would make a delete silently miss. Omitting
    /// `kSecAttrAccessible` is tidiness rather than necessity; it is an attribute of the
    /// stored item and is not used to constrain a match.
    private static var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
