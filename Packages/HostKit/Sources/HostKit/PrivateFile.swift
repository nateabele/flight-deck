import Foundation

/// File-scope so it resolves to rename(2), not a `rename` method on whatever type is in scope.
func posixRename(_ from: String, _ to: String) -> Int32 { rename(from, to) }

/// The one way hostd writes a state file that must never be readable by another user:
/// `controllers.json` (every controller's key) and `enrollments-spent.json`. Shared so the two
/// cannot drift on the details below, each of which closed a real hole.
enum PrivateFile {
    /// The root is forced to 0700 every time (also tightening one that pre-existed wider). The
    /// temp file is created exclusively at 0600, written and fsynced before the rename, so the
    /// bytes are never on disk under a wider mode and a crash mid-write leaves the old file
    /// intact rather than a truncated one.
    static func save(_ data: Data, named name: String, in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let tmp = root.appendingPathComponent("\(name).tmp").path
        unlink(tmp)   // a leftover from a crash would make O_EXCL fail forever
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { throw posixError() }
        func fail() -> Error { let e = posixError(); close(fd); unlink(tmp); return e }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n < 0 { if errno == EINTR { continue }; throw fail() }
            offset += n
        }
        guard fsync(fd) == 0 else { throw fail() }
        close(fd)
        guard posixRename(tmp, root.appendingPathComponent(name).path) == 0 else {
            let e = posixError(); unlink(tmp); throw e
        }
    }

    static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// "Missing" is decided from the read's own error, not a second look at the path: checking
    /// `fileExists` afterwards races another writer's first rename on the same root.
    static func isMissingFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
    }
}
