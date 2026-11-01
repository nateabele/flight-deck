import Foundation

/// The additive, user-edit-preserving contract of `CodexBundledSkill`, for the one-file
/// `peer-messaging` skill. A distinct managed directory avoids changing a user's delegate skill
/// or developer instructions.
enum PeerMessagingSkill {
    static func install(source: URL, home: URL) throws {
        _ = try CodexBundledSkill.peerMessaging.install(
            entries: [.init(path: CodexBundledSkill.skillFile, data: try Data(contentsOf: source))],
            codexHome: home)
    }
}
