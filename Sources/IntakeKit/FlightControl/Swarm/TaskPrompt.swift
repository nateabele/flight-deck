import Foundation

/// The first prompt a swarm agent gets (spec §4 step 6). Agent-facing text: it names `br`
/// commands verbatim, which is why it is built here and not as UI copy.
public enum TaskPrompt {
    /// Under `PromptText.maxCharacters` (8,000) with room to spare, so the prompt always passes
    /// the gate `SessionStore.submitPrompt` applies to every typed prompt.
    public static let budget = 7_500

    public static func text(for task: TaskDetail) -> String {
        let head = "Your task is \(task.id): \(clean(task.title))."
        let tail = """
            Reserve the files you will edit with Agent Mail before you edit them.
            When the acceptance criteria hold and your work is committed, run `br close \(task.id)`.
            If you are blocked, say so in one line that starts with BLOCKED:, then stop.
            """
        var description = clean(task.description).trimmingCharacters(in: .whitespacesAndNewlines)
        var acceptance = clean(task.acceptance).trimmingCharacters(in: .whitespacesAndNewlines)
        let pointer = "… (cut; run `br show \(task.id)` for the rest)"

        func assemble() -> String {
            var parts = [head]
            if !description.isEmpty { parts.append(description) }
            if !acceptance.isEmpty { parts.append("Acceptance criteria:\n" + acceptance) }
            parts.append(tail)
            return parts.joined(separator: "\n\n")
        }

        // Cut the description first (the agent can `br show` it), then the criteria, never the
        // instructions: those are what make the swarm work at all.
        var text = assemble()
        if text.count > budget {
            let over = text.count - budget
            if description.count > over + pointer.count {
                description = String(description.prefix(description.count - over - pointer.count)) + pointer
            } else {
                description = pointer
            }
            text = assemble()
        }
        if text.count > budget {
            let over = text.count - budget
            acceptance = acceptance.count > over + pointer.count
                ? String(acceptance.prefix(acceptance.count - over - pointer.count)) + pointer
                : pointer
            text = assemble()
        }
        return text
    }

    /// CRLF to LF, and every C0 control but newline and tab dropped, with DEL — the set
    /// `PromptText.rejection` refuses. An escape sequence inside a paste can close the bracketed
    /// paste early and turn the rest into keystrokes.
    private static func clean(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }))
    }
}
