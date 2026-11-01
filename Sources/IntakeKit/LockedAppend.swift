import Foundation

/// An exclusive `flock` around a read-then-append on a file, so "read the highest seq / the ids
/// already written, then write the next" is one step across processes, not just across threads.
/// The app, the phone path and the detached runners all append to the same JSONL files, and
/// without this two of them can read the same max and write the same seq.
///
/// `flock` rather than a lock file's existence: the kernel drops it when the holder dies, so a
/// crashed writer can never leave a lock behind.
public enum LockedAppend {
    public struct LockError: Error, Equatable {
        public let file: String
    }

    /// Runs `body` holding `LOCK_EX` on `url` itself, with the file's current contents. Creates
    /// the file (and its directory) first. For a file whose readers must not be blocked by or
    /// confused with the lock, use `withLock(on:_:)` on a sibling.
    public static func withLockedFile<T>(
        _ url: URL, _ body: (FileHandle, Data) throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // open(O_CREAT), never `FileManager.createFile`: that replaces the file with a new inode,
        // so two processes racing to create it would each lock a different file and exclude
        // nobody. O_CLOEXEC: a child spawned while the lock is held (a runner starting an agent
        // CLI on another thread) would otherwise inherit the descriptor, and an `flock` lives as
        // long as any descriptor on it, so every append would wait on that child.
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw LockError(file: url.lastPathComponent) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            throw LockError(file: url.lastPathComponent)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        let existing = try handle.readToEnd() ?? Data()
        return try body(handle, existing)
    }

    /// Runs `body` holding the lock on `lockURL`, a file that exists only to be locked. The
    /// commands files are read by `commands(after:)` with no lock, so the lock lives beside them
    /// rather than on them.
    public static func withLock<T>(on lockURL: URL, _ body: () throws -> T) throws -> T {
        try withLockedFile(lockURL) { _, _ in try body() }
    }

    /// `commands.jsonl` -> `commands.jsonl.lock`, in the same directory.
    public static func lockURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".lock")
    }

    /// The lines of a JSONL file, split on the newline BYTE before any decoding. Decoding the
    /// whole file as one UTF-8 string fails outright when a torn tail ends inside a multi-byte
    /// character, which would empty every line, read the max seq as 0 and reuse seq 1. Here only
    /// a line that is not valid UTF-8 on its own is dropped.
    public static func lines(of data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { slice in
            let line = Data(slice)
            return String(data: line, encoding: .utf8) == nil ? nil : line
        }
    }
}
