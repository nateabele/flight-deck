import CryptoKit
import Darwin
import HostKit
import XCTest
@testable import FlightDeck

/// The trust gate's digest and approval store. Every path is a fresh temp folder; the real
/// `~/Library/Application Support/Flight Deck` is never read or written.
final class ProviderTrustTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderTrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func folder(_ name: String, files: [(String, String)]) throws -> URL {
        let root = tmp.appendingPathComponent(name)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    func testDigestIsStableAndIgnoresCreationOrder() throws {
        let a = try folder("a", files: [("provider.toml", "x"), ("sub/gen.py", "print(1)"), ("z.txt", "z")])
        let b = try folder("b", files: [("z.txt", "z"), ("sub/gen.py", "print(1)"), ("provider.toml", "x")])
        let first = try ProviderTrust.digest(folder: a)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, try ProviderTrust.digest(folder: a))
        XCTAssertEqual(first, try ProviderTrust.digest(folder: b))
    }

    func testChangingOneByteChangesTheDigest() throws {
        let dir = try folder("p", files: [("provider.toml", "abc"), ("gen.py", "print(1)")])
        let before = try ProviderTrust.digest(folder: dir)
        try Data("print(2)".utf8).write(to: dir.appendingPathComponent("gen.py"))
        XCTAssertNotEqual(before, try ProviderTrust.digest(folder: dir))
    }

    func testMovingBytesBetweenFilesChangesTheDigest() throws {
        let a = try folder("a", files: [("a", "xy"), ("b", "z")])
        let b = try folder("b", files: [("a", "x"), ("b", "yz")])
        XCTAssertNotEqual(try ProviderTrust.digest(folder: a), try ProviderTrust.digest(folder: b))
    }

    func testRenamingAFileChangesTheDigest() throws {
        let a = try folder("a", files: [("gen.py", "x")])
        let b = try folder("b", files: [("gen2.py", "x")])
        XCTAssertNotEqual(try ProviderTrust.digest(folder: a), try ProviderTrust.digest(folder: b))
    }

    func testSymlinkIsRefusedAndNamed() throws {
        let dir = try folder("p", files: [("provider.toml", "x"), ("sub/real.txt", "r")])
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("sub/link.txt"), withDestinationURL: dir.appendingPathComponent("provider.toml"))
        XCTAssertThrowsError(try ProviderTrust.digest(folder: dir)) { error in
            XCTAssertEqual(error as? ProviderTrust.DigestError, .symlink("sub/link.txt"))
            XCTAssertTrue("\(error)".contains("sub/link.txt"))
        }
    }

    func testApprovalRoundTripsAndOnlyMatchesTheSameDigest() throws {
        let store = ProviderTrustStore(directory: tmp.appendingPathComponent("store"))
        XCTAssertFalse(store.isApproved(repoPath: "/r", providerID: "p", digest: "d1"))
        try store.approve(repoPath: "/r", providerID: "p", digest: "d1")
        XCTAssertTrue(store.isApproved(repoPath: "/r", providerID: "p", digest: "d1"))
        XCTAssertFalse(store.isApproved(repoPath: "/r", providerID: "p", digest: "d2"))
        XCTAssertFalse(store.isApproved(repoPath: "/other", providerID: "p", digest: "d1"))
        // A new digest replaces the old one rather than adding beside it.
        try store.approve(repoPath: "/r", providerID: "p", digest: "d2")
        XCTAssertEqual(store.approvals().count, 1)
        XCTAssertFalse(store.isApproved(repoPath: "/r", providerID: "p", digest: "d1"))
    }

    func testStoreFileHasTheDocumentedShape() throws {
        let dir = tmp.appendingPathComponent("store")
        try ProviderTrustStore(directory: dir).approve(repoPath: "/r", providerID: "p", digest: "d")
        let data = try Data(contentsOf: dir.appendingPathComponent("provider-trust.json"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["repoPath", "providerID", "digest", "approvedAt"])
    }

    func testCorruptStoreReadsAsNoApprovals() throws {
        let dir = tmp.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("provider-trust.json"))
        XCTAssertFalse(ProviderTrustStore(directory: dir).isApproved(repoPath: "/r", providerID: "p", digest: "d"))
    }

    func testRevoke() throws {
        let store = ProviderTrustStore(directory: tmp.appendingPathComponent("store"))
        try store.approve(repoPath: "/r", providerID: "p", digest: "d")
        try store.revoke(repoPath: "/r", providerID: "p")
        XCTAssertFalse(store.isApproved(repoPath: "/r", providerID: "p", digest: "d"))
    }

    func testHiddenFilesAreDigested() throws {
        // The manifest can name .DS_Store as the generator, so skipping it would leave code uncovered.
        let dir = try folder("p", files: [("provider.toml", "x"), (".DS_Store", "one")])
        let before = try ProviderTrust.digest(folder: dir)
        try Data("two".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        XCTAssertNotEqual(before, try ProviderTrust.digest(folder: dir))
    }

    func testExecutableBitChangesDigest() throws {
        let dir = try folder("p", files: [("gen.sh", "echo")])
        let before = try ProviderTrust.digest(folder: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("gen.sh").path)
        XCTAssertNotEqual(before, try ProviderTrust.digest(folder: dir))
    }

    /// Only the owner's bit decides whether the provider's own uid can exec the file. Folding in
    /// any class's bit let `chmod u+x` on a 0o645 file (other-exec already set) go unnoticed.
    func testOwnerExecBitChangesDigest() throws {
        let dir = try folder("p", files: [("gen.sh", "echo")])
        let path = dir.appendingPathComponent("gen.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o645], ofItemAtPath: path)
        let before = try ProviderTrust.digest(folder: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o745], ofItemAtPath: path)
        XCTAssertNotEqual(before, try ProviderTrust.digest(folder: dir))
    }

    /// A permission read that fails must not hash as "not executable": that is a guess, and a
    /// wrong guess approves a runnable file as data.
    func testUnreadablePermissionsThrow() throws {
        let dir = try folder("p", files: [("provider.toml", "x"), ("gen.sh", "echo")])
        struct NoStat: Error {}
        XCTAssertThrowsError(try ProviderTrust.digest(folder: dir, permissions: { url in
            if url.lastPathComponent == "gen.sh" { throw NoStat() }
            return 0o644
        })) { error in
            XCTAssertEqual(error as? ProviderTrust.DigestError, .unreadable("gen.sh"))
        }
    }

    func testFifoIsRefused() throws {
        let dir = try folder("p", files: [("provider.toml", "x")])
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("pipe").path, 0o644), 0)
        XCTAssertThrowsError(try ProviderTrust.digest(folder: dir)) { error in
            XCTAssertEqual(error as? ProviderTrust.DigestError, .notRegularFile("pipe"))
        }
    }

    func testApproveRefusesToOverwriteACorruptTrustFile() throws {
        let dir = tmp.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("provider-trust.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try ProviderTrustStore(directory: dir).approve(repoPath: "/r", providerID: "p", digest: "d")) {
            XCTAssertEqual($0 as? ProviderTrustStore.StoreError, .trustFileUnreadable)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
    }
    // MARK: - Final review: size caps

    private func sparse(_ dir: URL, _ name: String, bytes: UInt64) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    /// A repo can commit a file of any size; the digest is taken on the Settings path, so a
    /// file over 10 MB is refused by name without being read.
    func testAFileOverTenMegabytesIsRefusedByName() throws {
        let dir = try folder("p", files: [("provider.toml", "x")])
        try sparse(dir.appendingPathComponent("bin"), "big.bin", bytes: 10 * 1024 * 1024 + 1)
        let start = Date()
        XCTAssertThrowsError(try ProviderTrust.digest(folder: dir)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("bin/big.bin"), text)
            XCTAssertTrue(text.contains("10 MB"), text)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testAFileOfExactlyTenMegabytesIsDigested() throws {
        let dir = try folder("p", files: [("provider.toml", "x")])
        try sparse(dir, "edge.bin", bytes: 10 * 1024 * 1024)
        XCTAssertEqual(try ProviderTrust.digest(folder: dir).count, 64)
    }

    func testAFolderOverFiftyMegabytesIsRefusedNamingTheFileThatCrossedIt() throws {
        let dir = try folder("p", files: [("provider.toml", "x")])
        for i in 0..<6 { try sparse(dir, "part\(i).bin", bytes: 9 * 1024 * 1024) }
        let start = Date()
        XCTAssertThrowsError(try ProviderTrust.digest(folder: dir)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("50 MB"), text)
            XCTAssertTrue(text.contains("part5.bin"), text)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the folder was read before its size was known")
    }

    /// Streaming the bytes must not change a digest an approval already stored: the stream is
    /// path, NUL, 8-byte big-endian length, owner-exec byte, bytes, file by file in path order.
    func testDigestFormatIsUnchanged() throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let dir = try folder("p", files: [("provider.toml", "x"), ("sub/gen.sh", "echo")])
        try body.write(to: dir.appendingPathComponent("blob"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("sub/gen.sh").path)
        var hasher = SHA256()
        for (path, data, exec) in [("blob", body, false), ("provider.toml", Data("x".utf8), false), ("sub/gen.sh", Data("echo".utf8), true)] {
            hasher.update(data: Data(path.utf8) + Data([0]))
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data([exec ? 1 : 0]) + data)
        }
        let expected = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ProviderTrust.digest(folder: dir), expected)
    }
}
