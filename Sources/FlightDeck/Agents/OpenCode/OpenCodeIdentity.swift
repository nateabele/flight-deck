import CryptoKit
import Foundation
import IntakeKit

/// How an OpenCode session id (`ses_…`) becomes the `UUID` every Flight Deck registry is keyed
/// by, and how the store gets back from one to the other.
///
/// **Why a derived UUID rather than widening `conversationID` to `String`.** OpenCode chooses
/// its own ids — `POST /session` takes no id (checked against 1.18.34's OpenAPI schema), so
/// there is no way to hand it one Flight Deck minted. The alternative was a repo-wide
/// `UUID`→`String` change: 169 references across 32 files, the wire format, `sessions.json`
/// and every search row. A name-based UUID gets the same result with none of that: it is a
/// pure function of the session id, so two processes — the store and the search builder,
/// which runs off the main actor and never talks to the store — agree on it without sharing
/// any state, and nothing has to be persisted to remember the mapping.
///
/// **The reverse direction rides on the transcript path, not on a table.** Every OpenCode
/// binding's `transcriptURL` is its mirror file (see `OpenCodeMirror`), named `<ses_id>.jsonl`.
/// `Session.transcriptPath` already persists that path for codex, so a restored tab recovers
/// its session id from a field the store was already saving.
enum OpenCodeIdentity {
    /// RFC 4122 §4.3 name-based UUID (version 5, SHA-1) in a namespace of our own. Version 5
    /// rather than a bare hash so the result is a well-formed UUID that no other generator in
    /// this app — all of which mint version 4 — can ever collide with by construction.
    static let namespace = UUID(uuidString: "6F70656E-636F-4465-8000-466C69676874")!

    static func conversationID(forSession sessionID: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(sessionID.utf8))
        var digest = Array(Insecure.SHA1.hash(data: bytes)).prefix(16)
        digest[digest.startIndex + 6] = (digest[digest.startIndex + 6] & 0x0F) | 0x50
        digest[digest.startIndex + 8] = (digest[digest.startIndex + 8] & 0x3F) | 0x80
        let d = Array(digest)
        return UUID(uuid: (
            d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
            d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]
        ))
    }

    /// The session id a mirror file is named after, or nil for any other path. Strict about
    /// the prefix so a codex rollout or a claude transcript handed here by mistake answers
    /// "not OpenCode's" rather than a garbage id that would then be sent to the server.
    static func sessionID(fromTranscript url: URL?) -> String? {
        guard let url, url.pathExtension == "jsonl" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("ses_"), stem.count > 4,
              stem.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        return stem
    }
}
