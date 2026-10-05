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

/// File-scope so it resolves to rename(2), not `ControllerStore.rename(slot:to:)`.
private func posixRename(_ from: String, _ to: String) -> Int32 { rename(from, to) }

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
        controllers = Self.load(root: root)
    }

    /// Missing file means a fresh host: empty. Anything else (unreadable, undecodable) is
    /// moved aside, not ignored: starting empty and then overwriting on the next `add` would
    /// silently destroy every pairing, so the bytes are kept for recovery and the failure is
    /// logged.
    private static func load(root: URL) -> [PairedController] {
        let file = root.appendingPathComponent("controllers.json")
        do {
            return try decoder.decode([PairedController].self, from: Data(contentsOf: file))
        } catch {
            // "Missing" is decided from the read's own error, not a second look at the path:
            // checking `fileExists` afterwards raced the first `persist` of another store on
            // the same root — the read missed the file, the rename then created it, and this
            // moved the just-written controllers aside as "corrupt", un-pairing them on disk.
            if Self.isMissingFile(error) { return [] }
            let aside = root.appendingPathComponent("controllers.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            FileHandle.standardError.write(Data(
                "ControllerStore: \(file.path) unreadable (\(error)); moving to \(aside.lastPathComponent)\n".utf8))
            if posixRename(file.path, aside.path) == 0 { chmod(aside.path, 0o600) }
            return []
        }
    }

    static func isMissingFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
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

    /// False when the slot is unknown.
    public func rename(slot: UUID, to name: String) throws -> Bool {
        try mutate { list in
            guard let i = list.firstIndex(where: { $0.slot == slot }) else { return false }
            list[i].name = name
            return true
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

    /// The root is forced to 0700 every time (also tightening one that pre-existed wider). The
    /// temp file is created exclusively at 0600, written and fsynced before the rename, so the
    /// secrets are never on disk under a wider mode and a crash mid-write leaves the old file
    /// intact rather than a truncated one that would silently un-pair every controller.
    private func persist(_ list: [PairedController]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let tmp = root.appendingPathComponent("controllers.json.tmp").path
        let data = try Self.encoder.encode(list)
        unlink(tmp)   // a leftover from a crash would make O_EXCL fail forever
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        func fail() -> Error { let e = Self.posixError(); close(fd); unlink(tmp); return e }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n < 0 { if errno == EINTR { continue }; throw fail() }
            offset += n
        }
        guard fsync(fd) == 0 else { throw fail() }
        close(fd)
        guard posixRename(tmp, file.path) == 0 else { let e = Self.posixError(); unlink(tmp); throw e }
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
