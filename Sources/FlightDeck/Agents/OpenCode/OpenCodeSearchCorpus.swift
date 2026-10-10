import Foundation
import IntakeKit

/// OpenCode's history as ⌘K's corpus.
///
/// The conversations are rows in each account's `opencode.db`; what the index builder reads
/// is lines from a file. So `transcripts` brings each matching session's mirror up to date
/// (`OpenCodeMirror.sync`, the same writer the live runtime uses, under the same file lock) and
/// hands the builder the mirror — one file format for live tailing, paging and search alike.
///
/// A result's `conversationID` is the DERIVED UUID (`OpenCodeIdentity`), not the `ses_…` id,
/// because every resume path from a search hit parses the conversation id as a UUID and
/// matches it against tabs' pinned ids — which, for OpenCode, are derived the same way. The
/// session id itself rides along in the mirror's file name, which is the hit's
/// `transcriptPath`.
struct OpenCodeSearchCorpus: AgentSearchCorpus {
    var listing: @Sendable (String) -> [String] = { SearchCorpus.defaultListing($0) }
    var mirrorRoot: URL = OpenCodeMirror.defaultRoot

    func transcripts(forProjects projects: [String], accounts: [AgentAccount]) -> [TranscriptRef] {
        guard !projects.isEmpty else { return [] }
        let homes = accounts.filter { $0.agent == .opencode && !$0.isRemoved }.map(\.home)
        guard !homes.isEmpty else { return [] }
        var candidates: [String: (projectPath: String, workingDirectory: String)] = [:]
        for project in projects {
            for directory in SearchCorpus.candidateWorkingDirectories(forProjectAt: project, listing: listing) {
                let key = Self.normalize(directory)
                if candidates[key] == nil { candidates[key] = (project, directory) }
            }
        }
        guard !candidates.isEmpty else { return [] }
        return homes.flatMap { home -> [TranscriptRef] in
            guard let database = OpenCodeMirror.databaseURL(home: home),
                  let sessions = try? OpenCodeDatabase(url: database).topLevelSessions()
            else { return [] }
            return sessions.compactMap { row in
                guard let candidate = candidates[Self.normalize(row.directory)] else { return nil }
                let mirror = OpenCodeMirror.url(forSession: row.id, database: database, root: mirrorRoot)
                // Best effort: a session whose rows cannot be read yet still gets a ref, and an
                // empty mirror simply indexes nothing until the next pass.
                _ = try? OpenCodeMirror.sync(sessionID: row.id, database: database, mirror: mirror)
                guard FileManager.default.fileExists(atPath: mirror.path) else { return nil }
                return TranscriptRef(
                    url: mirror, projectPath: candidate.projectPath, accountHome: home,
                    workingDirectory: row.directory,
                    conversationID: OpenCodeIdentity.conversationID(forSession: row.id).uuidString.lowercased(),
                    agent: .opencode, provenance: nil,
                    indexedName: Self.isPlaceholderTitle(row.title) ? nil : row.title,
                    modified: row.updated
                )
            }
        }
    }

    func indexedMessages(inLine line: String, conversationID: String, at offset: Int) -> [IndexedMessage] {
        Self.indexedMessages(inLine: line, conversationID: conversationID, at: offset)
    }

    static func indexedMessages(inLine line: String, conversationID: String, at offset: Int) -> [IndexedMessage] {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["type"] as? String == "message"
        else { return [] }
        let role: IndexedMessage.Role = record["role"] as? String == "user" ? .user : .assistant
        let text = (record["parts"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" && $0["synthetic"] as? Bool != true }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let timestamp = (record["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return [IndexedMessage(
            conversationID: conversationID, role: role, text: text, timestamp: timestamp, offset: offset
        )]
    }

    /// The session's own title is authoritative — it is what OpenCode's session list shows —
    /// unless it is a placeholder: OpenCode's `New session - <date>`, or Flight Deck's own
    /// `session N` that nobody has renamed.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        if let name = ref.indexedName, !Self.isFlightDeckPlaceholder(name) {
            return .authoritative(name)
        }
        for line in lines {
            guard let message = Self.indexedMessages(inLine: line, conversationID: "", at: 0).first,
                  message.role == .user
            else { continue }
            return .fallback(message.text)
        }
        if let name = ref.indexedName { return .fallback(name) }
        return .unknown
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.isEmpty || title.hasPrefix("New session - ")
    }

    static func isFlightDeckPlaceholder(_ name: String) -> Bool {
        guard name.hasPrefix("session ") else { return false }
        let rest = name.dropFirst("session ".count)
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
