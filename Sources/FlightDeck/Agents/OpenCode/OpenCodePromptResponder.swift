import FleetKit
import Foundation
import IntakeKit
import OSLog

/// Answers an OpenCode dialog by the id of the request that raised it.
///
/// The call id on an OpenCode `OpenPrompt` IS the request id (`per_…` / `que_…`) — the mirror
/// logs requests under their own ids, see `OpenCodeMirror` — so an answer here names exactly
/// the request the phone's card was drawn from. A request that has since been answered on the
/// Mac, or dropped by a server restart, fails on the server with `PermissionNotFoundError`
/// rather than landing on whatever dialog replaced it: the failure mode keystrokes cannot offer.
///
/// **What is checked here, before anything is sent, is the same set `answerPrompt` checks for
/// keystrokes**: the answer has the prompt's shape, a chosen index exists, and its label
/// matches this Mac's own copy of the question. The label that is SENT is the Mac's copy, never
/// the client's — OpenCode answers by label, so this keeps "nothing a client sends becomes the
/// answer" true even though no keystroke is involved.
///
/// **`always` is unreachable from here, by construction.** `PromptAnswer.allow` maps to
/// `once`; there is no case that names OpenCode's durable grant, for the reason
/// `AgentDialogDriver.allowRow` gives — "and don't ask again" must never be granted from a
/// pocket.
struct OpenCodePromptResponder: AgentPromptResponder {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "opencode"
    )

    /// The labels to send, one array per question, or nil when the answer does not fit.
    static func labels(for answer: PromptAnswer, questions: [PromptQuestion]) -> [[String]]? {
        switch answer {
        case .option(let index, let label):
            guard questions.count == 1, let question = questions.first,
                  question.options.indices.contains(index),
                  question.options[index].label == label
            else { return nil }
            return [[question.options[index].label]]
        case .answers(let selections):
            guard selections.count == questions.count else { return nil }
            var out: [[String]] = []
            for (question, chosen) in zip(questions, selections) {
                guard !chosen.isEmpty, question.multiSelect || chosen.count == 1 else { return nil }
                var labels: [String] = []
                for selection in chosen {
                    guard question.options.indices.contains(selection.index),
                          question.options[selection.index].label == selection.label
                    else { return nil }
                    labels.append(question.options[selection.index].label)
                }
                out.append(labels)
            }
            return out
        case .allow, .deny:
            return nil
        }
    }

    func answer(_ open: OpenPrompt, with answer: PromptAnswer, for target: AgentTarget) -> Bool {
        guard let adapter = target.adapter as? OpenCodeAdapter else { return false }
        let directory = target.location.workingDirectory
        let send: @MainActor (OpenCodeClient) async throws -> Void
        switch (open, answer) {
        case (.permission(let id, _, _), .allow):
            send = { try await $0.replyPermission(id, reply: "once", directory: directory) }
        case (.permission(let id, _, _), .deny):
            send = { try await $0.replyPermission(id, reply: "reject", directory: directory) }
        case (.question(let id, _), .deny):
            send = { try await $0.rejectQuestion(id, directory: directory) }
        case (.question(let id, let questions), _):
            guard let labels = Self.labels(for: answer, questions: questions) else { return false }
            send = { try await $0.replyQuestion(id, answers: labels, directory: directory) }
        default:
            return false
        }
        let callID = open.callID
        Task { @MainActor in
            do {
                try await send(try adapter.client())
            } catch {
                Self.logger.error(
                    "reply to \(callID, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return true
    }

    /// Rejects every request pending in this tab's conversation — its own session's and its
    /// subagents', since a child's request is drawn in the parent's TUI (see `OpenCodeSignal`).
    func abort(for target: AgentTarget) {
        guard let adapter = target.adapter as? OpenCodeAdapter,
              let root = OpenCodeIdentity.sessionID(fromTranscript: target.location.binding.transcriptURL)
        else { return }
        let directory = target.location.workingDirectory
        Task { @MainActor in
            do {
                let client = try adapter.client()
                let pending = try await client.pendingRequests(inTreeOf: root, directory: directory)
                for id in pending.permissions {
                    try? await client.replyPermission(id, reply: "reject", directory: directory)
                }
                for id in pending.questions {
                    try? await client.rejectQuestion(id, directory: directory)
                }
            } catch {
                Self.logger.error(
                    "abort for \(root, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
