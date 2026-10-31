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

        public var description: String {
            switch self {
            case .symlink(let path): return "\(path) is a symbolic link; providers may not contain links"
            case .unreadable(let path): return "could not read \(path) to check the provider"
            }
        }
    }

    /// SHA-256 over every file in `folder`, in sorted relative-path order. Each entry is the
    /// path, a NUL, the length as 8 big-endian bytes, then the bytes. The NUL and the length
    /// make the stream unambiguous, so moving bytes from one file's tail to the next file's
    /// head cannot give the same digest.
    public static func digest(folder: URL) throws -> String {
        var files: [(path: String, url: URL)] = []
        try collect(folder, prefix: "", into: &files)
        // Sorted by UTF-8 bytes, not by locale: the digest must not depend on the user's language.
        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }

        var hasher = SHA256()
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { throw DigestError.unreadable(file.path) }
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(_ dir: URL, prefix: String, into files: inout [(path: String, url: URL)]) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let names: [URL]
        do {
            names = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        } catch {
            throw DigestError.unreadable(prefix.isEmpty ? dir.lastPathComponent : prefix)
        }
        for url in names {
            let name = url.lastPathComponent
            // Finder writes this on its own; counting it would ask the user to re-approve a
            // provider they never touched.
            if name == ".DS_Store" { continue }
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { throw DigestError.symlink(relative) }
            if values?.isDirectory == true {
                try collect(url, prefix: relative, into: &files)
            } else {
                files.append((relative, url))
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
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ProviderApproval].self, from: data)) ?? []
    }

    public func isApproved(repoPath: String, providerID: String, digest: String) -> Bool {
        approvals().contains { $0.repoPath == repoPath && $0.providerID == providerID && $0.digest == digest }
    }

    /// Replaces any earlier approval of the same provider in the same repo, so the file holds
    /// one digest per pair and an old version stays unapproved.
    public func approve(repoPath: String, providerID: String, digest: String, now: Date = Date()) throws {
        var all = approvals().filter { !($0.repoPath == repoPath && $0.providerID == providerID) }
        all.append(ProviderApproval(repoPath: repoPath, providerID: providerID, digest: digest, approvedAt: now))
        try write(all)
    }

    public func revoke(repoPath: String, providerID: String) throws {
        try write(approvals().filter { !($0.repoPath == repoPath && $0.providerID == providerID) })
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
