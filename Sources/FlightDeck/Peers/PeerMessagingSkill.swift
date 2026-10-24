import CryptoKit
import Foundation

/// The same additive, user-edit-preserving contract as CodexDelegateSkill. A distinct
/// managed directory avoids changing a user's delegate skill or developer instructions.
enum PeerMessagingSkill {
    static func install(source: URL, home: URL) throws {
        let fm = FileManager.default
        let folder = home.appendingPathComponent("skills/flightdeck-peer-messaging")
        let target = folder.appendingPathComponent("SKILL.md")
        let marker = folder.appendingPathComponent(".flightdeck-managed")
        let ours = try Data(contentsOf: source)
        let disk = try? Data(contentsOf: target)
        let previous = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        if let disk {
            guard disk == ours || previous == hash(disk) else { return }
        } else if previous != nil { return } // a deliberate user deletion stays deleted
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try ours.write(to: target, options: .atomic)
        try Data((hash(ours) + "\n").utf8).write(to: marker, options: .atomic)
    }
}
