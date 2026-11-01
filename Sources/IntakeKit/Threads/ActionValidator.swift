import Foundation

/// Checks a turn's actions against the plan they target before any of them is kept (spec §5,
/// R6). A refusal is a sentence the agent can act on: ThreadRunner feeds it back as an error
/// block, and the retry fixes the action rather than guessing again. Nothing is applied from an
/// answer that has a refusal — a half-applied answer would leave the reply describing changes
/// that never happened.
public enum ActionValidator {
    /// A proposed diff whose quote was found exactly once: where it sits on the plan, and the
    /// text it replaces as the plan has it (which may differ in whitespace from the quote).
    public struct LocatedDiff: Equatable, Sendable {
        /// The action's position in the answer, which names it deterministically.
        public var index: Int
        public var anchor: NoteAnchor
        public var old: String
        public var new: String
    }

    public struct Outcome: Equatable, Sendable {
        public var diffs: [LocatedDiff]
        public var errors: [String]
        public var isValid: Bool { errors.isEmpty }
    }

    /// `checkpoint` is the version the turn's workspace was built from, `plan` its effective
    /// plan.
    public static func validate(_ actions: [ThreadAction], checkpoint: Int, plan: String) -> Outcome {
        var diffs: [LocatedDiff] = []
        var errors: [String] = []
        var questionIDs = Set<String>()
        for (i, action) in actions.enumerated() {
            let n = "Action \(i + 1)"
            switch action {
            case .proposeDiff(let d):
                guard d.checkpoint == checkpoint else {
                    errors.append("\(n) (proposeDiff) targets checkpoint \(d.checkpoint), but the workspace is checkpoint \(checkpoint). Quote the plan you were given.")
                    continue
                }
                guard d.replacement != d.quote else {
                    errors.append("\(n) (proposeDiff): the replacement is the same as the quote, so it changes nothing.")
                    continue
                }
                switch locate(quote: d.quote, prefix: d.prefix, suffix: d.suffix, in: plan) {
                case .success(let range):
                    diffs.append(LocatedDiff(index: i, anchor: NoteAnchor(checkpoint: checkpoint, selecting: range, in: plan),
                                             old: String(plan[range]), new: d.replacement))
                case .failure(let why):
                    errors.append("\(n) (proposeDiff): \(why.message)")
                }
            case .addNote(let note):
                if note.kind == .question {
                    errors.append("\(n) (addNote): a note can't be a question; ask it with askQuestion.")
                    continue
                }
                if !note.accepts(kind: note.kind) {
                    errors.append("\(n) (addNote): a \(note.kind.rawValue) note needs words.")
                    continue
                }
                if let anchor = note.anchor {
                    guard anchor.checkpoint == checkpoint else {
                        errors.append("\(n) (addNote) is anchored on checkpoint \(anchor.checkpoint), but the workspace is checkpoint \(checkpoint).")
                        continue
                    }
                    if case .failure(let why) = locate(quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, in: plan) {
                        errors.append("\(n) (addNote): \(why.message)")
                    }
                }
            case .askQuestion(let q):
                if q.id.trimmingCharacters(in: .whitespaces).isEmpty {
                    errors.append("\(n) (askQuestion): the question needs an id.")
                } else if !questionIDs.insert(q.id).inserted {
                    errors.append("\(n) (askQuestion): the question id \"\(q.id)\" is used twice; ids must be unique.")
                }
                if q.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("\(n) (askQuestion): the question has no text.")
                }
                if (q.kind == .single || q.kind == .multi) && q.options.isEmpty {
                    errors.append("\(n) (askQuestion): a \(q.kind.rawValue) question needs options.")
                }
                let optionIDs = q.options.map(\.id)
                if Set(optionIDs).count != optionIDs.count {
                    errors.append("\(n) (askQuestion): option ids must be unique.")
                }
                if !q.recommended.allSatisfy(Set(optionIDs).contains) {
                    errors.append("\(n) (askQuestion): a recommended option is not one of the options.")
                }
            }
        }
        return Outcome(diffs: errors.isEmpty ? diffs : [], errors: errors)
    }

    public enum Refusal: Error, Equatable {
        case empty, missing, ambiguous(Int)

        public var message: String {
            switch self {
            case .empty: "the quote is empty."
            case .missing: "the quote is not in the plan. Quote the plan's words exactly."
            case .ambiguous(let n): "ambiguous: the quote matches \(n) places. Quote more context, or give a prefix and suffix that pick one."
            }
        }
    }

    /// Where `quote` sits, if exactly one place fits (R6). The quote with its prefix and suffix
    /// is tried first, since context is what tells two copies of a phrase apart; then the quote
    /// alone, which is fine when it occurs once (context the agent paraphrased); then the same
    /// with whitespace runs collapsed, the leniency `NoteAnchor.locate` gives a reflowed line.
    /// `NoteAnchor.locate` itself picks the best of several, which is right for a note and
    /// wrong for an edit: an edit applied to the wrong copy changes the wrong sentence.
    public static func locate(quote: String, prefix: String, suffix: String, in plan: String)
        -> Result<Range<String.Index>, Refusal> {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        let exact = occurrences(of: quote, in: plan)
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 {
            let fitting = exact.filter { r in
                plan[..<r.lowerBound].hasSuffix(prefix) && plan[r.upperBound...].hasPrefix(suffix)
            }
            if fitting.count == 1 && !(prefix.isEmpty && suffix.isEmpty) { return .success(fitting[0]) }
            return .failure(.ambiguous(fitting.count > 1 ? fitting.count : exact.count))
        }
        // Not there verbatim: whitespace-lenient, but still exactly once.
        let collapsed = collapse(quote).trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return .failure(.missing) }
        let lenient = occurrences(of: collapsed, in: collapse(plan)).count
        guard lenient == 1, let range = NoteAnchor(checkpoint: 0, quote: quote, prefix: prefix, suffix: suffix).locate(in: plan)
        else { return .failure(lenient > 1 ? .ambiguous(lenient) : .missing) }
        return .success(range)
    }

    /// `plan` with `diff` applied: the located passage replaced by its new text. nil when the
    /// passage can't be found exactly once in `plan` any more.
    public static func apply(old: String, anchor: NoteAnchor, new: String, to plan: String) -> String? {
        guard case .success(let range) = locate(quote: old, prefix: anchor.prefix, suffix: anchor.suffix, in: plan)
        else { return nil }
        var out = plan
        out.replaceSubrange(range, with: new)
        return out
    }

    private static func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = haystack.startIndex
        while from < haystack.endIndex, let r = haystack.range(of: needle, range: from..<haystack.endIndex) {
            found.append(r)
            from = haystack.index(after: r.lowerBound)
        }
        return found
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
