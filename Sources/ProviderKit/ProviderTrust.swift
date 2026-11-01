import CryptoKit
import Foundation

/// The trust gate for repo providers (spec §9). A repo is untrusted input, and a provider with a
/// generator runs code, so the user approves one exact folder: the approval stores the folder's
/// SHA-256, and any later change makes it ask again.
public enum ProviderTrust {
    public enum DigestError: Error, Equatable, CustomStringConvertible {
        /// Refused rather than followed: a link can point out of the folder, or be retargeted
        /// after approval without a single byte of the folder changing.
        case symlink(String)
        case unreadable(String)
        case notRegularFile(String)
        /// One file over `maxFileBytes`.
        case fileTooLarge(String)
        /// The folder's running total passed `maxFolderBytes` at this file.
        case folderTooLarge(String)

        public var description: String {
            switch self {
            case .symlink(let path): return "\(path) is a symbolic link; providers may not contain links"
            case .notRegularFile(let path): return "\(path) is not a regular file"
            case .unreadable(let path): return "could not read \(path) to check the provider"
            case .fileTooLarge(let path):
                return "\(path) is larger than \(ProviderTrust.maxFileBytes >> 20) MB; a provider file may be at most that"
            case .folderTooLarge(let path):
                return "the provider is larger than \(ProviderTrust.maxFolderBytes >> 20) MB in all (passed at \(path))"
            }
        }
    }

    /// SHA-256 over every file in `folder`, in sorted relative-path order. Each entry is the
    /// path, a NUL, the length as 8 big-endian bytes, one byte for the owner's executable bit, then the bytes. The NUL and the length
    /// make the stream unambiguous, so moving bytes from one file's tail to the next file's
    /// head cannot give the same digest.
    /// A repo is untrusted and Settings digests every repo provider in it, so no file is read
    /// past these: one file at most 10 MiB, the folder at most 50 MiB.
    public static let maxFileBytes = 10 << 20
    public static let maxFolderBytes = 50 << 20

    public static func digest(folder: URL) throws -> String {
        try digest(folder: folder, permissions: { url in
            struct NoMode: Error {}
            guard let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int else {
                throw NoMode()
            }
            return mode
        })
    }

    /// `permissions` is a parameter only so a test can make the mode read fail, which a real
    /// file system will not do on demand for a file it just let us read.
    static func digest(folder: URL, permissions: (URL) throws -> Int) throws -> String {
        var files: [(path: String, url: URL, size: Int)] = []
        try collect(folder, prefix: "", into: &files)
        // Sorted by UTF-8 bytes, not by locale: the digest must not depend on the user's language.
        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }

        // Every size is known before a byte is read, so an oversized folder costs a listing.
        var total = 0
        for file in files {
            guard file.size <= maxFileBytes else { throw DigestError.fileTooLarge(file.path) }
            total += file.size
            guard total <= maxFolderBytes else { throw DigestError.folderTooLarge(file.path) }
        }

        var hasher = SHA256()
        for file in files {
            // One descriptor, not following a link and not blocking on a FIFO swapped in since
            // the listing; its size is the one hashed, and the bytes are streamed in chunks.
            let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw DigestError.unreadable(file.path) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw DigestError.unreadable(file.path) }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw DigestError.notRegularFile(file.path) }
            let size = Int(info.st_size)
            guard size <= maxFileBytes else { throw DigestError.fileTooLarge(file.path) }
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            var length = UInt64(size).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            // The owner's executable bit, so a generator made runnable after approval asks
            // again. Owner only: the generator runs as the file's owner, and folding in any
            // class's bit hid `chmod u+x` on a file whose other-exec bit was already set.
            // A failed read throws: hashing it as "not executable" would be a guess.
            guard let mode = try? permissions(file.url) else { throw DigestError.unreadable(file.path) }
            hasher.update(data: Data([mode & 0o100 != 0 ? 1 : 0]))
            // Exactly `size` bytes: a file that grows or shrinks mid-read is unreadable, not
            // hashed under a length it no longer has.
            var remaining = size
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while remaining > 0 {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, remaining)) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw DigestError.unreadable(file.path) }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                remaining -= n
            }
            var probe: UInt8 = 0
            guard read(fd, &probe, 1) == 0 else { throw DigestError.unreadable(file.path) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(_ dir: URL, prefix: String, into files: inout [(path: String, url: URL, size: Int)]) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let names: [URL]
        do {
            names = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        } catch {
            throw DigestError.unreadable(prefix.isEmpty ? dir.lastPathComponent : prefix)
        }
        for url in names {
            let name = url.lastPathComponent
            // No file is skipped, not even .DS_Store: the manifest can name any file as the
            // generator, so a skipped name is code the approval would not cover.
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { throw DigestError.symlink(relative) }
            if values?.isDirectory == true {
                try collect(url, prefix: relative, into: &files)
            } else if values?.isRegularFile == true {
                guard let size = values?.fileSize else { throw DigestError.unreadable(relative) }
                files.append((relative, url, size))
            } else {
                // A FIFO, socket or device: reading one can block forever, and it is no file a
                // provider has a reason to ship.
                throw DigestError.notRegularFile(relative)
            }
        }
    }
}

/// One user decision: this exact folder of this provider, in this repo, may run.
public struct ProviderApproval: Codable, Equatable, Sendable {
    public var repoPath: String
    public var providerID: String
    public var digest: String
    public var approvedAt: Date

    public init(repoPath: String, providerID: String, digest: String, approvedAt: Date) {
        self.repoPath = repoPath
        self.providerID = providerID
        self.digest = digest
        self.approvedAt = approvedAt
    }
}

/// `provider-trust.json`, a plain list of approvals. The directory is a parameter so tests never
/// touch the real one.
public struct ProviderTrustStore: Sendable {
    public enum StoreError: Error, Equatable { case trustFileUnreadable, fileIsReadable }

    public static let fileName = "provider-trust.json"

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flight Deck", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = ProviderTrustStore.defaultDirectory) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// An unreadable or corrupt file reads as no approvals. Failing closed asks the user again,
    /// where failing open would run a generator nobody approved.
    public func approvals() -> [ProviderApproval] {
        (try? load()) ?? []
    }

    /// Throws for a file that exists but cannot be decoded; a missing file is simply empty.
    private func load() throws -> [ProviderApproval] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { throw StoreError.trustFileUnreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let all = try? decoder.decode([ProviderApproval].self, from: data) else {
            throw StoreError.trustFileUnreadable
        }
        return all
    }

    /// True when the file exists but cannot be read as approvals. Settings explains this and
    /// offers `moveAside()`, because approve and revoke refuse a corrupt file.
    public var isUnreadable: Bool {
        do { _ = try load(); return false } catch { return true }
    }

    /// Renames a corrupt trust file to `provider-trust.corrupt-<timestamp>.json`, so it is kept
    /// for a look and the next approval starts a fresh file. Every provider then asks again.
    @discardableResult
    public func moveAside(now: Date = Date()) throws -> URL {
        // A file repaired since the person looked holds approvals worth keeping.
        guard isUnreadable else { throw StoreError.fileIsReadable }
        let stamp = String(Int(now.timeIntervalSince1970))
        var target = directory.appendingPathComponent("provider-trust.corrupt-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = directory.appendingPathComponent("provider-trust.corrupt-\(stamp)-\(n).json")
        }
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }

    public func isApproved(repoPath: String, providerID: String, digest: String) -> Bool {
        approvals().contains { $0.repoPath == repoPath && $0.providerID == providerID && $0.digest == digest }
    }

    /// Replaces any earlier approval of the same provider in the same repo, so the file holds
    /// one digest per pair and an old version stays unapproved.
    public func approve(repoPath: String, providerID: String, digest: String, now: Date = Date()) throws {
        // Refuses a corrupt file instead of overwriting it, which would drop every other approval.
        var all = try load().filter { !($0.repoPath == repoPath && $0.providerID == providerID) }
        all.append(ProviderApproval(repoPath: repoPath, providerID: providerID, digest: digest, approvedAt: now))
        try write(all)
    }

    public func revoke(repoPath: String, providerID: String) throws {
        try write(try load().filter { !($0.repoPath == repoPath && $0.providerID == providerID) })
    }

    private func write(_ all: [ProviderApproval]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic so a crash mid-write cannot leave half a file, which would read as "nothing
        // approved" and silently drop every approval.
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }
}
