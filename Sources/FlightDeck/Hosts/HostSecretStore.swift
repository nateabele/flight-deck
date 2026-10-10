import Foundation
import Security

/// Where each paired host's TLS-PSK secret lives, by slot.
///
/// `Sendable` because `HostService` reads the secrets off the main thread at launch: a
/// Keychain read can block (a locked keychain, a slow `securityd`), and launch must not.
protocol HostSecretStoring: AnyObject, Sendable {
    /// May block for as long as the user leaves a Keychain prompt unanswered: never call it on
    /// the main thread or on the Swift concurrency pool. `HostService` reads on a GCD thread.
    func read(_ slot: UUID) -> HostSecretRead
    func set(_ secret: Data, for slot: UUID) throws
    func remove(slot: UUID)
}

extension HostSecretStoring {
    /// The secret, or nil whatever the reason it could not be had.
    func secret(for slot: UUID) -> Data? {
        if case .found(let secret) = read(slot) { return secret }
        return nil
    }
}

/// What one Keychain read came back with. A missing item and an unreadable one are kept apart
/// because they need different things from the user: the first a re-pair, the second only a
/// click on the Keychain prompt, after which a retry succeeds with the same key.
enum HostSecretRead: Equatable, Sendable {
    case found(Data)
    /// No item for this slot: only pairing again can mint a key.
    case missing
    /// The item is there but could not be read: the user denied the prompt, the keychain is
    /// locked, or `securityd` failed. Worth retrying.
    case failed(status: OSStatus)
}

/// Why a secret could not be written. Carries the raw `OSStatus` for the reason
/// `PairedMacStoreError` does: the number is the whole diagnosis.
enum HostSecretStoreError: Error, Equatable {
    case keychainWriteFailed(status: OSStatus)
}

/// One generic-password item per host: service `dev.flightdeck.host`, account the slot.
///
/// One item per slot, unlike the phone's single `KeychainPairedMacStore` item, because a
/// controller holds many hosts and forgetting one must not rewrite the others' secrets.
/// The metadata stays in `hosts.json`; a slot whose secret is missing is surfaced by
/// `HostService` as needing a re-pair rather than silently dropped.
final class KeychainHostSecretStore: HostSecretStoring {
    private let service: String

    /// `service` is a parameter only so the one Keychain test can use a throwaway name that
    /// can never touch a real host's secret.
    init(service: String = "dev.flightdeck.host") {
        self.service = service
    }

    /// Blocks while a Keychain prompt is up. The items live in the legacy file keychain,
    /// whose ACL trusts the code signature that created them, so the first launch of every
    /// re-signed build asks "Flight Deck wants to use … dev.flightdeck.host" and this call
    /// waits on the answer: 2026-10-10, for over two hours with no host link opened.
    func read(_ slot: UUID) -> HostSecretRead {
        var query = identity(slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(status: errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status: status)
        }
    }

    /// Update in place, inserting only when there is nothing to update — the shape
    /// `KeychainPairedMacStore.save` documents, so there is never a moment with no secret.
    func set(_ secret: Data, for slot: UUID) throws {
        let updated = SecItemUpdate(identity(slot) as CFDictionary,
                                    [kSecValueData as String: secret] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw HostSecretStoreError.keychainWriteFailed(status: updated)
        }
        var attributes = identity(slot)
        attributes[kSecValueData as String] = secret
        // Never synced: an iCloud-synced host key would let every Mac on the account drive
        // that host without ever having paired with it.
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw HostSecretStoreError.keychainWriteFailed(status: added)
        }
    }

    func remove(slot: UUID) {
        SecItemDelete(identity(slot) as CFDictionary)
    }

    private func identity(_ slot: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.uuidString
        ]
    }
}

/// No persistence. For tests, and for a UITest reset launch, which must never write the
/// developer's real Keychain.
final class InMemoryHostSecretStore: HostSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: Data] = [:]

    init() {}

    func read(_ slot: UUID) -> HostSecretRead {
        lock.withLock { secrets[slot] }.map(HostSecretRead.found) ?? .missing
    }

    func set(_ secret: Data, for slot: UUID) {
        lock.withLock { secrets[slot] = secret }
    }

    func remove(slot: UUID) {
        _ = lock.withLock { secrets.removeValue(forKey: slot) }
    }
}
