import Foundation
import Security

/// Why a `PairedMac` could not be written.
///
/// Carries the raw `OSStatus` rather than flattening every keychain refusal into one case,
/// because the status is the whole diagnosis: `errSecMissingEntitlement` (-34018) means the
/// build has no keychain access group — an unsigned build, which is a developer problem — and
/// says nothing about the user's device, while a real `errSecInteractionNotAllowed` would.
/// The UI shows one sentence either way; the log needs the number.
public enum PairedMacStoreError: Error, Equatable, Sendable {
    /// The record could not be turned into JSON. Not reachable in practice — `PairedMac` is
    /// `Codable` primitives plus its own manual `Body` — but it is a failure, not an assert.
    case encodingFailed
    /// The keychain refused the write.
    case keychainWriteFailed(status: OSStatus)
}

/// Where the phone keeps `PairedMac`. `AnyObject`-bound so a reference to the store can be
/// shared and mutated in place rather than copied.
///
/// `save` throws rather than returning `Bool` for one reason worth stating: `Bool` would drop
/// the `OSStatus`, and every real failure seen so far has been diagnosed by that number. The
/// in-memory store simply never throws — a non-throwing method witnesses a throwing
/// requirement — so nothing but the keychain pays for it.
public protocol PairedMacStoring: AnyObject {
    func load() -> PairedMac?
    func save(_ mac: PairedMac) throws
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
    /// is the expected first-save case and falls through to the insert; anything else throws.
    ///
    /// Both failure paths throw rather than trap: an encode that cannot fail in practice
    /// (`PairedMac` is `Codable` primitives plus the manual `Body` above) and a keychain write
    /// that can fail for real (entitlement misconfiguration, access-group mismatch).
    ///
    /// These used to be `assertionFailure`, which is the worst of both endings. In debug it
    /// killed the app — twice, on an unsigned simulator build with no keychain access group,
    /// `errSecMissingEntitlement` (-34018) — and each time it was "fixed" by re-signing rather
    /// than by handling the failure, which is why it kept coming back. In release
    /// `assertionFailure` compiles out entirely, so the write silently did nothing and the
    /// user paired, saw it succeed, and lost the pairing on the next launch with nothing on
    /// screen to explain it. The old comment here even conceded the second half and left it
    /// as somebody else's problem; reporting the failure is what makes it anyone's.
    public func save(_ mac: PairedMac) throws {
        guard let data = try? JSONEncoder().encode(mac) else {
            throw PairedMacStoreError.encodingFailed
        }
        // Only the payload changes. The two attributes that keep the secret on one device
        // were set at insert and are deliberately not re-specified here.
        let updated = SecItemUpdate(
            Self.identityQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw PairedMacStoreError.keychainWriteFailed(status: updated)
        }
        let added = SecItemAdd(Self.attributes(for: data) as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw PairedMacStoreError.keychainWriteFailed(status: added)
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
