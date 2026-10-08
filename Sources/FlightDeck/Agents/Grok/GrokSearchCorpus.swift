import FleetKit
import Foundation

/// grok's half of ⌘K.
///
/// A walk of each grok account's `sessions/<encoded cwd>/<id>/`, reading `summary.json` for
/// the session's cwd, kind and title, and `updates.jsonl` for its text. Not grok's own
/// `session_search.sqlite`: that is grok's private cache, its schema is unversioned, and the
/// index here already holds every other agent's text in one shape.
///
/// **Headless sessions are kept, but ranked as automated.** Flight Control's planning seats run
/// grok headless in the same home (`summary.json.session_kind == "headless"`); they are real
/// work worth finding, and they are not something a person typed — the same split codex's
/// `exec` provenance draws, so they carry that provenance.
struct GrokSearchCorpus: AgentSearchCorpus {
    var listing: @Sendable (String) -> [String] = { SearchCorpus.defaultListing($0) }
    var read: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }

    func transcripts(forProjects projects: [String], accounts: [AgentAccount]) -> [TranscriptRef] {
        guard !projects.isEmpty else { return [] }
        let grokAccounts = accounts.filter { $0.agent == .grok }
        guard !grokAccounts.isEmpty else { return [] }

        var candidates: [String: (projectPath: String, workingDirectory: String)] = [:]
        for project in projects {
            for directory in SearchCorpus.candidateWorkingDirectories(forProjectAt: project, listing: listing) {
                let key = Self.normalize(directory)
                if candidates[key] == nil { candidates[key] = (project, directory) }
            }
        }
        guard !candidates.isEmpty else { return [] }

        return grokAccounts.flatMap { account -> [TranscriptRef] in
            let root = GrokSessionFiles.sessionsRoot(home: account.home)
            return listing(root.path).flatMap { cwdDirectory -> [TranscriptRef] in
                let cwdURL = root.appendingPathComponent(cwdDirectory, isDirectory: true)
                return listing(cwdURL.path).compactMap { id -> TranscriptRef? in
                    guard UUID(uuidString: id) != nil else { return nil }
                    let directory = cwdURL.appendingPathComponent(id, isDirectory: true)
                    guard let meta = read(directory.appendingPathComponent(GrokSessionFiles.summaryName))
                            .flatMap(Self.meta(fromSummary:)),
                          let candidate = candidates[Self.normalize(meta.cwd)]
                    else { return nil }
                    let transcript = directory.appendingPathComponent(GrokSessionFiles.transcriptName)
                    let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return TranscriptRef(
                        url: transcript, projectPath: candidate.projectPath, accountHome: account.home,
                        workingDirectory: meta.cwd, conversationID: id.lowercased(), agent: .grok,
                        provenance: meta.headless ? TranscriptHit.automatedProvenance : nil,
                        indexedName: meta.title, modified: modified
                    )
                }
            }
        }
    }

    /// The conversation, not the machinery: the user's prompts and grok's replies. Reasoning
    /// and tool traffic are left out for `CodexSearchCorpus`'s reason — search should find what
    /// somebody asked for, not everything a thought happened to mention.
    func indexedMessages(inLine line: String, conversationID: String, at offset: Int) -> [IndexedMessage] {
        GrokTimelineMapper.items(inLine: line, at: offset).compactMap { item in
            let role: IndexedMessage.Role
            switch item.kind {
            case .userTurn: role = .user
            case .assistantText: role = .assistant
            default: return nil
            }
            let text = item.body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let timestamp = item.at.flatMap(Self.timestamps.date(from:))
            return IndexedMessage(conversationID: conversationID, role: role, text: text,
                                  timestamp: timestamp, offset: offset)
        }
    }

    /// grok's own title (`summary.json`, manual or auto — the name its own `/resume` picker
    /// shows) is authoritative; failing that, the first thing the user asked.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        if let name = ref.indexedName, !name.isEmpty { return .authoritative(name) }
        for (index, line) in lines.enumerated() {
            if let first = GrokTimelineMapper.items(inLine: line, at: index).first(where: { $0.kind == .userTurn }) {
                return .fallback(first.body.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return .unknown
    }

    struct Meta: Equatable {
        let cwd: String
        let title: String?
        let headless: Bool
    }

    /// `info.cwd` — the literal directory the session ran in, which the encoded directory name
    /// above it only approximates (it becomes a hash past 255 bytes).
    static func meta(fromSummary data: Data) -> Meta? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["info"] as? [String: Any],
              let cwd = info["cwd"] as? String
        else { return nil }
        return Meta(cwd: cwd, title: GrokSessionFiles.summary(fromData: data)?.title,
                    headless: object["session_kind"] as? String == "headless")
    }

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
