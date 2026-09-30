import Foundation

/// The feedback document an agent reads when a plan is sent back — built on the Mac, because
/// Plannotator does not build it anywhere the Mac can reach.
///
/// **Why this exists.** Plannotator's `POST /api/deny` gives the hook `body.feedback` verbatim
/// and otherwise `"Plan rejected by user"`; it never reads its own annotation store. The
/// `# Plan Feedback` document the browser's "Send Feedback" sends is composed by the browser,
/// client-side, from the annotations it holds. So until this type existed, a comment posted
/// from the phone landed in the gate's sidebar and never reached the agent, which could only
/// guess what was wrong — confirmed against a live `plannotator` 0.27.8 gate on 2026-09-30.
///
/// **The format is the browser's, byte for byte, for the shapes the phone can make** (a pinned
/// `COMMENT`, a `GLOBAL_COMMENT`). `PlanFeedbackTests.testMatchesWhatTheBrowserSends` pins it
/// against a capture of the real button; an agent reviewed in the browser and on the phone
/// should not see two dialects.
enum PlanFeedback {

    struct Comment: Equatable {
        let text: String
        /// The verbatim plan text the comment is pinned to; `nil` for a plan-wide comment.
        let originalText: String?

        init(text: String, originalText: String?) {
            self.text = text
            // The store serves a global comment's anchor as `""`; an empty anchor is no anchor,
            // not a `Feedback on: ""` heading.
            self.originalText = originalText?.isEmpty == false ? originalText : nil
        }
    }

    /// `nil` when there is nothing to say, so the caller omits `feedback` and Plannotator
    /// keeps its own default rather than announcing zero pieces of feedback.
    ///
    /// `note` — the footer box on the phone — is the last general piece: the reader typed it
    /// after reading the whole plan, and numbering it keeps the hook's "address ALL of the
    /// feedback" instruction covering it.
    static func compose(comments: [Comment], note: String?) -> String? {
        var pieces = comments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            pieces.append(Comment(text: note, originalText: nil))
        }
        guard !pieces.isEmpty else { return nil }

        var out = "# Plan Feedback\n\n"
        out += "I've reviewed this plan and have \(pieces.count) piece\(pieces.count > 1 ? "s" : "") of feedback:\n\n"
        for (n, piece) in pieces.enumerated() {
            if let anchor = piece.originalText {
                out += "## \(n + 1). Feedback on: \"\(anchor)\"\n"
            } else {
                out += "## \(n + 1). General feedback about the plan\n"
            }
            // Every line quoted, where the browser quotes only the first: the phone's text box
            // takes newlines, and an unquoted second line reads as the agent's own prose — or
            // as a heading, if it starts with `#`.
            out += piece.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return out + "---\n"
    }
}
