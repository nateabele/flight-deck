import Foundation
import Darwin

/// Descriptor-relative file operations for `RepoCommitter`.
///
/// A path is looked up again every time it is used, so a check on it proves nothing about the next
/// call. Here a directory is opened once, with `O_NOFOLLOW | O_DIRECTORY`, and every later delete,
/// write and mkdir goes through that descriptor (`unlinkat`, `openat`, `mkdirat`). If a component
/// is swapped for a symlink after it was opened, the descriptor still names the real directory.
struct SafeTree {
    struct Fail: Error, Equatable {
        /// `ELOOP`/`ENOTDIR`/`EEXIST` on a component: something that is not a plain directory.
        var notPlain: Bool
        var detail: String
        /// The component the call was on.
        var name: String = ""
    }

    /// An owned directory descriptor.
    final class Dir {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
        deinit { close(fd) }
    }

    private static func fail(_ what: String) -> Fail {
        let e = errno
        return Fail(notPlain: e == ELOOP || e == ENOTDIR || e == EEXIST, detail: "\(what): \(String(cString: strerror(e)))", name: what)
    }

    static func openRoot(_ path: String) throws -> Dir {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw fail(path) }
        return Dir(fd: fd)
    }

    /// nil when `name` does not exist. A symlink or a non-directory throws.
    static func openChild(_ parent: Dir, _ name: String) throws -> Dir? {
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd >= 0 { return Dir(fd: fd) }
        if errno == ENOENT { return nil }
        throw fail(name)
    }

    /// Opens `name`, making it first if it is missing.
    static func openOrMake(_ parent: Dir, _ name: String) throws -> Dir {
        if let d = try openChild(parent, name) { return d }
        if mkdirat(parent.fd, name, 0o755) != 0, errno != EEXIST { throw fail(name) }
        // Re-opened with NOFOLLOW: if something else won the race with a symlink, this throws.
        guard let d = try openChild(parent, name) else { throw Fail(notPlain: false, detail: "\(name): vanished") }
        return d
    }

    static func identity(_ d: Dir) -> (dev: dev_t, ino: ino_t)? {
        var st = stat()
        guard fstat(d.fd, &st) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    static func identity(ofPath path: String) -> (dev: dev_t, ino: ino_t)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    /// Deletes `name` under `parent`, recursively, never following a link. A symlink inside is
    /// unlinked itself, not what it points at.
    static func removeTree(_ parent: Dir, _ name: String) throws {
        guard let dir = try openChild(parent, name) else { return }
        try emptyDirectory(dir)
        if unlinkat(parent.fd, name, AT_REMOVEDIR) != 0, errno != ENOENT { throw fail(name) }
    }

    private static func emptyDirectory(_ dir: Dir) throws {
        let dupFD = dup(dir.fd)
        guard dupFD >= 0 else { throw fail("dup") }
        guard let stream = fdopendir(dupFD) else {
            let f = fail("fdopendir")
            close(dupFD)   // fdopendir owns it only on success
            throw f
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let e = readdir(stream) {
            let name = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        for name in names {
            var st = stat()
            guard fstatat(dir.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw fail(name)
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                try removeTree(dir, name)
            } else if unlinkat(dir.fd, name, 0) != 0, errno != ENOENT {
                throw fail(name)
            }
        }
    }

    /// Writes `data` to `relPath` under `dir`, making the folders on the way, never following a link.
    /// `O_EXCL`: the file must be new, so nothing is ever written through a hard link planted at the name.
    static func write(_ data: Data, to relPath: String, under dir: Dir) throws {
        var parts = relPath.split(separator: "/").map(String.init)
        guard let file = parts.popLast() else { throw Fail(notPlain: false, detail: "empty path") }
        var current = dir
        for p in parts { current = try openOrMake(current, p) }
        let fd = openat(current.fd, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw fail(file) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw fail(file) }
                offset += n
            }
        }
    }
}
