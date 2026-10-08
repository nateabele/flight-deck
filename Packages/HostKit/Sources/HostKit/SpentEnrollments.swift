import Foundation

/// The enrollment slots this host has redeemed, as `enrollments-spent.json` under the hostd
/// state root (0600, in the 0700 root, written like `controllers.json`).
///
/// An `EnrollmentPayload` stays valid for `maxAge` and is readable from the cloud metadata
/// service for the machine's whole life. Before this list the only reuse guard was "the slot is
/// already in `controllers.json`", so revoking a cloud controller reopened its slot, and the
/// same payload could enroll it again (secret and all) until it aged out. Keyed by slot, not by
/// payload bytes: a slot is minted fresh for every machine, and a payload re-signed with a new
/// name or idle threshold is still the same credential.
///
/// The file is read on every call rather than cached, so a second hostd process on the same
/// root (a `serve` restarted under a stale one) can never act on a stale copy.
public final class SpentEnrollments: @unchecked Sendable {
    private struct Entry: Codable, Equatable {
        let slot: UUID
        let issuedAt: Date
    }

    public enum Failure: Error, Equatable {
        /// The list exists but will not decode; it is left in place.
        case unreadable(path: String)
    }

    static let fileName = "enrollments-spent.json"
    private let root: URL
    private let lock = NSLock()

    public init(root: URL) { self.root = root }

    /// Records `slot` as redeemed. False when it already was, and then nothing is written.
    /// Entries whose payload is past `EnrollmentPayload.maxAge` are pruned on the way: that
    /// payload's own validation already refuses it, so the record guards nothing.
    public func spend(slot: UUID, issuedAt: Date, now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var entries = try load().filter { !Self.expired($0, now: now) }
        guard !entries.contains(where: { $0.slot == slot }) else { return false }
        entries.append(Entry(slot: slot, issuedAt: issuedAt))
        try persist(entries)
        return true
    }

    public func contains(_ slot: UUID, now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try load().contains { $0.slot == slot && !Self.expired($0, now: now) }
    }

    /// Undoes a `spend` whose enrollment then failed to store, so a disk error does not burn a
    /// machine's only enrollment file.
    public func forget(_ slot: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let entries = try load()
        let kept = entries.filter { $0.slot != slot }
        if kept.count != entries.count { try persist(kept) }
    }

    /// The same boundary `EnrollmentPayload.validate` uses: redeemable at exactly `maxAge`, so
    /// still guarded then.
    private static func expired(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.issuedAt) > EnrollmentPayload.maxAge
    }

    /// Missing is empty (no enrollment yet). Anything else throws, unlike `ControllerStore`'s
    /// move-aside: a list that cannot be read cannot prove a slot unspent, and starting empty
    /// would reopen every replay it was holding shut. The refusal names the file, so whoever
    /// reads it can delete a corrupt one deliberately.
    private func load() throws -> [Entry] {
        let file = root.appendingPathComponent(Self.fileName)
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            if PrivateFile.isMissingFile(error) { return [] }
            throw Failure.unreadable(path: file.path)
        }
        do { return try Self.decoder.decode([Entry].self, from: data) } catch {
            throw Failure.unreadable(path: file.path)
        }
    }

    private func persist(_ entries: [Entry]) throws {
        try PrivateFile.save(try Self.encoder.encode(entries), named: Self.fileName, in: root)
    }

    // Default (reference-date double) dates, like controllers.json: exact, where ISO 8601's
    // whole seconds would round an entry's expiry up to a second early.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()
}
