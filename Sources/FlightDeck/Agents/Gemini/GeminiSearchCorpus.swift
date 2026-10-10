import Foundation
import IntakeKit

/// Gemini's (agy's) half of ⌘K.
///
/// **The cwd comes from agy's summaries index, because the transcript does not carry one.**
/// `transcript_full.jsonl` records steps and nothing about where they ran; agy keeps each
/// conversation's workspaces in `conversation_summaries.workspace_uris` (agy-tui-facts §9). So
/// the walk reads that index once per account, read-only, and files every conversation whose
/// workspace is one of the open projects (or a worktree of one).
///
/// The index also carries the title, which is the same title `annotations/<id>.pbtxt` holds —
/// agy mirrors both — so it rides on `indexedName` and is authoritative when present.
struct GeminiSearchCorpus: AgentSearchCorpus {
    var listing: @Sendable (String) -> [String] = { SearchCorpus.defaultListing($0) }
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// The summaries index, by account root. A seam so tests need no SQLite file.
    var summaries: @Sendable (GeminiPaths) -> [GeminiSummary] = { GeminiSummaries.all(in: $0.summaries) ?? [] }

    func transcripts(forProjects projects: [String], accounts: [AgentAccount]) -> [TranscriptRef] {
        guard !projects.isEmpty else { return [] }
        let geminiAccounts = accounts.filter { $0.agent == .gemini }
        guard !geminiAccounts.isEmpty else { return [] }

        var candidates: [String: (projectPath: String, workingDirectory: String)] = [:]
        for project in projects {
            for directory in SearchCorpus.candidateWorkingDirectories(forProjectAt: project, listing: listing) {
                let key = Self.normalize(directory)
                if candidates[key] == nil { candidates[key] = (project, directory) }
            }
        }
        guard !candidates.isEmpty else { return [] }

        return geminiAccounts.flatMap { account -> [TranscriptRef] in
            let paths = GeminiPaths.forHome(account.home)
            return summaries(paths).compactMap { summary in
                guard let workspace = summary.workspaces.first(where: { candidates[Self.normalize($0)] != nil }),
                      let candidate = candidates[Self.normalize(workspace)]
                else { return nil }
                let url = paths.transcript(summary.conversationID)
                guard exists(url.path) else { return nil }
                return TranscriptRef(
                    url: url, projectPath: candidate.projectPath, accountHome: account.home,
                    workingDirectory: workspace, conversationID: GeminiPaths.name(summary.conversationID),
                    agent: .gemini, provenance: nil,
                    indexedName: summary.title.isEmpty ? nil : summary.title,
                    modified: summary.modified ?? .distantPast
                )
            }
        }
    }

    /// The user's request and the model's prose — what somebody would search for. Tool calls,
    /// tool results, thinking and agy's own system messages are left out, for the reason
    /// `CodexSearchCorpus` leaves out `response_item`: they would put machinery into results.
    func indexedMessages(inLine line: String, conversationID: String, at offset: Int) -> [IndexedMessage] {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = record["type"] as? String
        else { return [] }
        let role: IndexedMessage.Role
        let text: String?
        switch type {
        case "USER_INPUT":
            role = .user
            text = GeminiTimelineMapper.userText(record["content"] as? String)
        case "PLANNER_RESPONSE":
            role = .assistant
            text = (record["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return []
        }
        guard let text, !text.isEmpty else { return [] }
        let timestamp = (record["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return [IndexedMessage(conversationID: conversationID, role: role, text: text,
                               timestamp: timestamp, offset: offset)]
    }

    /// agy's own title is authoritative (it is either agy's auto-title or the user's `/rename`);
    /// without one, the first request names the conversation as a fallback.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        if let name = ref.indexedName, !name.isEmpty { return .authoritative(name) }
        for line in lines {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  record["type"] as? String == "USER_INPUT",
                  let text = GeminiTimelineMapper.userText(record["content"] as? String)
            else { continue }
            return .fallback(text)
        }
        return .unknown
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
