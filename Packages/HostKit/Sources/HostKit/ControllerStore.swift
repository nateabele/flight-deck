import Foundation

public struct PairedController: Codable, Sendable, Equatable {
    public let slot: UUID
    public var name: String
    public let secret: Data
    public let pairedAt: Date

    public init(slot: UUID, name: String, secret: Data, pairedAt: Date) {
        self.slot = slot
        self.name = name
        self.secret = secret
        self.pairedAt = pairedAt
    }
}

/// The host's paired controllers, persisted as `controllers.json` under `root`.
public final class ControllerStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var controllers: [PairedController]
    private var _onChange: (@Sendable () -> Void)?

    /// Read and written under the lock so a store handed to a transport thread can have its
    /// observer attached late without a data race.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); defer { lock.unlock() }; _onChange = newValue }
    }

    private var file: URL { root.appendingPathComponent("controllers.json") }

    public init(root: URL) {
        self.root = root
        let data = try? Data(contentsOf: root.appendingPathComponent("controllers.json"))
        controllers = data.flatMap { try? Self.decoder.decode([PairedController].self, from: $0) } ?? []
    }

    public func all() -> [PairedController] {
        lock.lock(); defer { lock.unlock() }
        return controllers
    }

    public func add(_ c: PairedController) throws {
        _ = try mutate { $0.append(c); return true }
    }

    /// False when the slot was not paired, so a caller can tell "revoked" from "nothing to do".
    @discardableResult
    public func revoke(slot: UUID) throws -> Bool {
        try mutate { list in
            let before = list.count
            list.removeAll { $0.slot == slot }
            return list.count != before
        }
    }

    private func mutate(_ change: (inout [PairedController]) -> Bool) throws -> Bool {
        lock.lock()
        var next = controllers
        let changed = change(&next)
        guard changed else { lock.unlock(); return false }
        do { try persist(next) } catch { lock.unlock(); throw error }
        controllers = next
        let notify = _onChange
        lock.unlock()
        // Outside the lock: an observer that calls `all()` must not deadlock.
        notify?()
        return true
    }

    /// Temp file created 0600 and then renamed over the target: the secrets are never on disk
    /// under a wider mode, even briefly, and a crash mid-write leaves the old file intact
    /// rather than a truncated one that would silently un-pair every controller.
    private func persist(_ list: [PairedController]) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = root.appendingPathComponent("controllers.json.tmp")
        let data = try Self.encoder.encode(list)
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        guard rename(tmp.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // Default (reference-date double) date strategy on purpose: it round-trips a Date exactly,
    // where seconds-since-1970 or ISO-8601 would shave sub-second precision.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
